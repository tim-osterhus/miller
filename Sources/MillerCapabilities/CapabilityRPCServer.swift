import Darwin
import Foundation

public typealias CapabilityRPCHandler = @Sendable (
    CapabilityRPCRequest
) async -> CapabilityRPCResponse

public struct CapabilityRPCEndpoint: Sendable {
    public let socketURL: URL
    public let token: CapabilityRPCSessionToken

    public var adapterEnvironment: [String: String] {
        [
            CapabilityRPCEnvironment.socketPath: socketURL.path,
            CapabilityRPCEnvironment.sessionToken: token.environmentValue,
        ]
    }
}

public enum CapabilityRPCRuntime {
    public static let managedChildName = "capability-bridge"

    public static var defaultTrustedParent: URL {
        URL(
            filePath: "/private/tmp/ai.millrace.miller-\(getuid())",
            directoryHint: .isDirectory
        )
    }

    public static var defaultManagedRoot: URL {
        managedRoot(in: defaultTrustedParent)
    }

    public static func managedRoot(in trustedParent: URL) -> URL {
        trustedParent.appending(
            path: managedChildName,
            directoryHint: .isDirectory
        )
    }

    public static func prepareManagedRoot(
        _ root: URL,
        trustedParent: URL
    ) throws {
        try validateAuthority(root: root, trustedParent: trustedParent)
        var value = stat()
        if lstat(root.path, &value) == 0 {
            try validateOwnedPrivateDirectory(value)
        } else {
            guard errno == ENOENT else { throw CapabilityRPCError.socketFailure }
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CapabilityRPCError.socketFailure
            }
            guard lstat(root.path, &value) == 0 else {
                throw CapabilityRPCError.socketFailure
            }
            try validateOwnedPrivateDirectory(value)
        }
    }

    public static func removeManagedRoot(
        _ root: URL,
        trustedParent: URL
    ) throws {
        try validateAuthority(root: root, trustedParent: trustedParent)
        var value = stat()
        guard lstat(root.path, &value) == 0 else {
            if errno == ENOENT { return }
            throw CapabilityRPCError.socketFailure
        }
        try validateOwnedPrivateDirectory(value)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
        } catch {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        guard children.isEmpty else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        guard rmdir(root.path) == 0 else {
            throw CapabilityRPCError.socketFailure
        }
    }

    private static func validateAuthority(
        root: URL,
        trustedParent: URL
    ) throws {
        guard root.isFileURL,
              trustedParent.isFileURL,
              root.path.hasPrefix("/"),
              trustedParent.path.hasPrefix("/"),
              root.path == managedRoot(in: trustedParent).path
        else { throw CapabilityRPCError.unsafeRuntimeRoot }

        try validateNoSymlinkComponents(trustedParent)
        var parentValue = stat()
        guard lstat(trustedParent.path, &parentValue) == 0 else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        try validateOwnedPrivateDirectory(parentValue)
    }

    private static func validateNoSymlinkComponents(_ url: URL) throws {
        guard url.path.hasPrefix("/") else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        var current = URL(filePath: "/", directoryHint: .isDirectory)
        for component in url.pathComponents.dropFirst() {
            current.append(path: component, directoryHint: .isDirectory)
            var value = stat()
            guard lstat(current.path, &value) == 0,
                  (value.st_mode & S_IFMT) != S_IFLNK
            else { throw CapabilityRPCError.unsafeRuntimeRoot }
        }
    }

    private static func validateOwnedPrivateDirectory(_ value: stat) throws {
        guard (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == geteuid(),
              (value.st_mode & 0o777) == 0o700
        else { throw CapabilityRPCError.unsafeRuntimeRoot }
    }
}

public actor CapabilityRPCServer {
    private let trustedParent: URL
    private let runtimeRoot: URL
    private let handler: CapabilityRPCHandler
    private var listener: Int32 = -1
    private var socketURL: URL?
    private var activeClients = Set<Int32>()
    private var clientTasks: [Int32: Task<Void, Never>] = [:]
    private var acceptTask: Task<Void, Never>?
    private var sessionToken: CapabilityRPCSessionToken?

    public init(
        trustedParent: URL,
        handler: @escaping CapabilityRPCHandler
    ) {
        self.trustedParent = trustedParent
        self.runtimeRoot = CapabilityRPCRuntime.managedRoot(in: trustedParent)
        self.handler = handler
    }

    deinit {
        if listener >= 0 { Darwin.close(listener) }
    }

    public func start() throws -> CapabilityRPCEndpoint {
        guard listener < 0 else { throw CapabilityRPCError.socketFailure }
        try CapabilityRPCRuntime.prepareManagedRoot(
            runtimeRoot,
            trustedParent: trustedParent
        )
        let socketURL = runtimeRoot.appending(path: "capability.sock")
        guard !FileManager.default.fileExists(atPath: socketURL.path) else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CapabilityRPCError.socketFailure }
        do {
            try bindUnixSocket(descriptor, path: socketURL.path)
            guard chmod(socketURL.path, 0o600) == 0,
                  Darwin.listen(descriptor, 8) == 0
            else { throw CapabilityRPCError.socketFailure }
        } catch {
            Darwin.close(descriptor)
            unlink(socketURL.path)
            try? CapabilityRPCRuntime.removeManagedRoot(
                runtimeRoot,
                trustedParent: trustedParent
            )
            throw error
        }

        let token = CapabilityRPCSessionToken.random()
        listener = descriptor
        self.socketURL = socketURL
        sessionToken = token
        let handler = self.handler
        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let client = Darwin.accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                guard let self else {
                    Darwin.close(client)
                    break
                }
                await self.accepted(
                    client,
                    token: token,
                    handler: handler
                )
            }
        }
        return CapabilityRPCEndpoint(socketURL: socketURL, token: token)
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            listener = -1
        }
        let clients = activeClients
        activeClients.removeAll()
        let tasks = clientTasks.values
        clientTasks.removeAll()
        for task in tasks { task.cancel() }
        for client in clients {
            shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        if let socketURL {
            unlink(socketURL.path)
        }
        self.socketURL = nil
        sessionToken = nil
        try? CapabilityRPCRuntime.removeManagedRoot(
            runtimeRoot,
            trustedParent: trustedParent
        )
    }

    private func accepted(
        _ descriptor: Int32,
        token: CapabilityRPCSessionToken,
        handler: @escaping CapabilityRPCHandler
    ) {
        activeClients.insert(descriptor)
        clientTasks[descriptor] = Task.detached(priority: .userInitiated) {
            [weak self] in
            await handleClient(descriptor, token: token, handler: handler)
            await self?.completed(descriptor)
        }
    }

    private func completed(_ descriptor: Int32) {
        clientTasks[descriptor] = nil
        if activeClients.remove(descriptor) != nil {
            Darwin.close(descriptor)
        }
    }
}

private func handleClient(
    _ descriptor: Int32,
    token: CapabilityRPCSessionToken,
    handler: @escaping CapabilityRPCHandler
) async {
    do {
        let firstFrame = try readRPCFrame(from: descriptor)
        guard let auth = try? CapabilityRPCCodec.decode(
            CapabilityRPCAuthenticationFrame.self, from: firstFrame
        ), constantTimeEqual(auth.token, token.bytes) else {
            try writeRPCFrame(
                CapabilityRPCResponseEnvelope(
                    requestID: UUID(),
                    response: .failed(nil, code: "authentication_failed")
                ),
                to: descriptor
            )
            return
        }

        let requestFrame = try readRPCFrame(from: descriptor)
        let request = try CapabilityRPCCodec.decode(
            CapabilityRPCRequestEnvelope.self, from: requestFrame
        )
        let response = await handler(request.request)
        try writeRPCFrame(
            CapabilityRPCResponseEnvelope(
                requestID: request.requestID,
                response: response
            ),
            to: descriptor
        )
    } catch {
        // A malformed or disconnected peer is closed without retaining payloads.
    }
}

func bindUnixSocket(_ descriptor: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw CapabilityRPCError.socketFailure
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        for (index, byte) in bytes.enumerated() {
            buffer[index] = UInt8(bitPattern: byte)
        }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            )
        }
    }
    guard result == 0 else { throw CapabilityRPCError.socketFailure }
}

func readRPCFrame(from descriptor: Int32) throws -> Data {
    var result = Data()
    result.reserveCapacity(4_096)
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 0 { throw CapabilityRPCError.peerDisconnected }
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw CapabilityRPCError.timedOut
            }
            throw CapabilityRPCError.peerDisconnected
        }
        if byte == UInt8(ascii: "\n") {
            guard !result.isEmpty else { throw CapabilityRPCError.malformedFrame }
            return result
        }
        result.append(byte)
        guard result.count <= CapabilityRPCCodec.maximumFrameBytes else {
            throw CapabilityRPCError.frameTooLarge
        }
    }
}

func writeRPCFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    var data = try CapabilityRPCCodec.encode(value)
    data.append(UInt8(ascii: "\n"))
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let count = Darwin.write(
                descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw CapabilityRPCError.timedOut
            } else {
                throw CapabilityRPCError.peerDisconnected
            }
        }
    }
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
