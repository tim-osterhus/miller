import Darwin
import Foundation

public typealias CapabilityRPCHandler = @Sendable (
    CapabilityRPCRequest
) async -> CapabilityRPCResponse

public struct CapabilityRPCEndpoint: Sendable {
    public let socketURL: URL
    public let token: CapabilityRPCSessionToken
    public let trustedParentURL: URL

    public var adapterEnvironment: [String: String] {
        [
            CapabilityRPCEnvironment.socketPath: socketURL.path,
            CapabilityRPCEnvironment.sessionToken: token.environmentValue,
            CapabilityRPCEnvironment.trustedParent: trustedParentURL.path,
        ]
    }
}

public enum CapabilityRPCRuntime {
    public static let managedChildName = "capability-bridge"
    public static let processLeaseName = "bridge.pid"
    public static let processLeaseMetadataName = "bridge.lease"

    public static var defaultTrustedParent: URL {
        URL(filePath: "/private/tmp", directoryHint: .isDirectory).appending(
            path: "ai.millrace.miller-\(getuid())",
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

    public static func currentProcessLeaseMetadata() throws -> String {
        let executable = try currentExecutablePath()
        let start = try currentProcessStartDescription()
        return [
            "pid=\(getpid())",
            "uid=\(geteuid())",
            "ppid=\(getppid())",
            "start=\(start)",
            "exec=\(executable)",
            "",
        ].joined(separator: "\n")
    }

    private static func currentExecutablePath() throws -> String {
        guard let raw = CommandLine.arguments.first, !raw.isEmpty else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        let currentDirectory = URL(
            filePath: FileManager.default.currentDirectoryPath,
            directoryHint: .isDirectory
        )
        let candidate = raw.hasPrefix("/")
            ? URL(filePath: raw).standardizedFileURL
            : URL(filePath: raw, relativeTo: currentDirectory).standardizedFileURL
        var value = stat()
        guard candidate.path.hasPrefix("/"),
              lstat(candidate.path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == geteuid(),
              access(candidate.path, X_OK) == 0
        else { throw CapabilityRPCError.unsafeRuntimeRoot }
        return candidate.path
    }

    private static func currentProcessStartDescription() throws -> String {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-p", "\(getpid())", "-o", "lstart="]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CapabilityRPCError.socketFailure
        }
        guard process.terminationStatus == 0,
              let value = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("\n")
        else { throw CapabilityRPCError.socketFailure }
        return value
    }

    fileprivate static func createExclusiveLeaseFile(
        at url: URL,
        payload: Data
    ) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        do {
            var value = stat()
            guard fstat(descriptor, &value) == 0,
                  (value.st_mode & S_IFMT) == S_IFREG,
                  value.st_uid == geteuid(),
                  (value.st_mode & 0o777) == 0o600
            else { throw CapabilityRPCError.unsafeRuntimeRoot }
            var offset = 0
            while offset < payload.count {
                let written = payload.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return 0 }
                    return Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        payload.count - offset
                    )
                }
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    throw CapabilityRPCError.socketFailure
                }
            }
            guard fsync(descriptor) == 0 else {
                throw CapabilityRPCError.socketFailure
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            unlink(url.path)
            throw error
        }
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

    public static func validateEndpoint(
        socketURL: URL,
        trustedParent: URL
    ) throws {
        let root = managedRoot(in: trustedParent)
        try validateAuthority(root: root, trustedParent: trustedParent)
        guard socketURL == root.appending(path: "capability.sock") else {
            throw CapabilityRPCError.unsafeRuntimeRoot
        }
        var rootValue = stat()
        var socketValue = stat()
        guard lstat(root.path, &rootValue) == 0,
              lstat(socketURL.path, &socketValue) == 0
        else { throw CapabilityRPCError.unsafeRuntimeRoot }
        try validateOwnedPrivateDirectory(rootValue)
        guard (socketValue.st_mode & S_IFMT) == S_IFSOCK,
              socketValue.st_uid == geteuid(),
              (socketValue.st_mode & 0o777) == 0o600
        else { throw CapabilityRPCError.unsafeRuntimeRoot }
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

public final class CapabilityRPCBridgeProcessLease: @unchecked Sendable {
    public let url: URL
    private let runtimeRoot: URL
    private let trustedParent: URL
    private let metadataURL: URL
    private let lock = NSLock()
    private var descriptor: Int32
    private var metadataDescriptor: Int32

    private init(
        url: URL,
        runtimeRoot: URL,
        trustedParent: URL,
        descriptor: Int32,
        metadataURL: URL,
        metadataDescriptor: Int32
    ) {
        self.url = url
        self.runtimeRoot = runtimeRoot
        self.trustedParent = trustedParent
        self.metadataURL = metadataURL
        self.descriptor = descriptor
        self.metadataDescriptor = metadataDescriptor
    }

    public static func acquire(trustedParent: URL) throws -> Self {
        let root = CapabilityRPCRuntime.managedRoot(in: trustedParent)
        let socket = root.appending(path: "capability.sock")
        try CapabilityRPCRuntime.validateEndpoint(
            socketURL: socket,
            trustedParent: trustedParent
        )
        let url = root.appending(path: CapabilityRPCRuntime.processLeaseName)
        let metadataURL = root.appending(
            path: CapabilityRPCRuntime.processLeaseMetadataName
        )
        let metadataDescriptor = try CapabilityRPCRuntime
            .createExclusiveLeaseFile(
                at: metadataURL,
                payload: Data(
                    try CapabilityRPCRuntime.currentProcessLeaseMetadata().utf8
                )
            )
        do {
            let descriptor = try CapabilityRPCRuntime.createExclusiveLeaseFile(
                at: url,
                payload: Data("\(getpid())\n".utf8)
            )
            return Self(
                url: url,
                runtimeRoot: root,
                trustedParent: trustedParent,
                descriptor: descriptor,
                metadataURL: metadataURL,
                metadataDescriptor: metadataDescriptor
            )
        } catch {
            Darwin.close(metadataDescriptor)
            unlink(metadataURL.path)
            throw error
        }
    }

    public func release() {
        lock.lock()
        let held = descriptor
        let heldMetadata = metadataDescriptor
        descriptor = -1
        metadataDescriptor = -1
        lock.unlock()

        if heldMetadata >= 0 {
            unlinkIfHeld(metadataURL, descriptor: heldMetadata)
            Darwin.close(heldMetadata)
        }
        if held >= 0 {
            unlinkIfHeld(url, descriptor: held)
            Darwin.close(held)
        }
        try? CapabilityRPCRuntime.removeManagedRoot(
            runtimeRoot,
            trustedParent: trustedParent
        )
    }

    private func unlinkIfHeld(_ file: URL, descriptor: Int32) {
        var heldValue = stat()
        var pathValue = stat()
        if fstat(descriptor, &heldValue) == 0,
           lstat(file.path, &pathValue) == 0,
           (pathValue.st_mode & S_IFMT) == S_IFREG,
           heldValue.st_dev == pathValue.st_dev,
           heldValue.st_ino == pathValue.st_ino
        {
            unlink(file.path)
        }
    }

    deinit { release() }
}

public actor CapabilityRPCServer {
    public static let maximumActiveClients = 8

    private let trustedParent: URL
    private let runtimeRoot: URL
    private let handler: CapabilityRPCHandler
    private let authenticationTimeout: Duration
    private let requestFrameTimeout: Duration
    private let responseWriteTimeout: Duration
    private var listener: Int32 = -1
    private var socketURL: URL?
    private var activeClients = Set<Int32>()
    private var clientTasks: [Int32: Task<Void, Never>] = [:]
    private var acceptTask: Task<Void, Never>?
    private var sessionToken: CapabilityRPCSessionToken?
    private var generation: UInt64 = 0

    public init(
        trustedParent: URL,
        authenticationTimeout: Duration = .seconds(2),
        requestFrameTimeout: Duration = .seconds(2),
        responseWriteTimeout: Duration = .seconds(2),
        handler: @escaping CapabilityRPCHandler
    ) {
        self.trustedParent = trustedParent
        self.runtimeRoot = CapabilityRPCRuntime.managedRoot(in: trustedParent)
        self.handler = handler
        self.authenticationTimeout = authenticationTimeout
        self.requestFrameTimeout = requestFrameTimeout
        self.responseWriteTimeout = responseWriteTimeout
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
        generation &+= 1
        let acceptedGeneration = generation
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
                    listener: descriptor,
                    generation: acceptedGeneration,
                    token: token,
                    handler: handler
                )
            }
        }
        return CapabilityRPCEndpoint(
            socketURL: socketURL,
            token: token,
            trustedParentURL: trustedParent
        )
    }

    public func stop() async {
        generation &+= 1
        let accepting = acceptTask
        accepting?.cancel()
        acceptTask = nil
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            listener = -1
        }
        await accepting?.value
        let clients = activeClients
        let tasks = Array(clientTasks.values)
        for task in tasks { task.cancel() }
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
        for task in tasks { await task.value }
        for client in activeClients { Darwin.close(client) }
        activeClients.removeAll()
        clientTasks.removeAll()
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
        listener acceptedListener: Int32,
        generation acceptedGeneration: UInt64,
        token: CapabilityRPCSessionToken,
        handler: @escaping CapabilityRPCHandler
    ) {
        guard generation == acceptedGeneration,
              listener == acceptedListener,
              activeClients.count < Self.maximumActiveClients,
              configureAcceptedSocket(descriptor)
        else {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            return
        }
        activeClients.insert(descriptor)
        let authenticationTimeout = self.authenticationTimeout
        let requestFrameTimeout = self.requestFrameTimeout
        let responseWriteTimeout = self.responseWriteTimeout
        clientTasks[descriptor] = Task.detached(priority: .userInitiated) {
            [weak self] in
            await handleClient(
                descriptor,
                token: token,
                authenticationTimeout: authenticationTimeout,
                requestFrameTimeout: requestFrameTimeout,
                responseWriteTimeout: responseWriteTimeout,
                handler: handler
            )
            await self?.completed(descriptor)
        }
    }

    private func completed(_ descriptor: Int32) {
        clientTasks[descriptor] = nil
        if activeClients.remove(descriptor) != nil {
            Darwin.close(descriptor)
        }
    }

    func activeClientCountForTesting() -> Int { activeClients.count }
}

private func handleClient(
    _ descriptor: Int32,
    token: CapabilityRPCSessionToken,
    authenticationTimeout: Duration,
    requestFrameTimeout: Duration,
    responseWriteTimeout: Duration,
    handler: @escaping CapabilityRPCHandler
) async {
    do {
        var reader = RPCFrameReader()
        let firstFrame = try reader.read(
            from: descriptor,
            deadline: try RPCOperationDeadline(timeout: authenticationTimeout)
        )
        guard let auth = try? CapabilityRPCCodec.decode(
            CapabilityRPCAuthenticationFrame.self, from: firstFrame
        ), constantTimeEqual(auth.token, token.bytes) else {
            try writeRPCFrame(
                CapabilityRPCResponseEnvelope(
                    requestID: UUID(),
                    response: .failed(nil, code: "authentication_failed")
                ),
                to: descriptor,
                deadline: try RPCOperationDeadline(timeout: responseWriteTimeout)
            )
            return
        }

        let requestFrame = try reader.read(
            from: descriptor,
            deadline: try RPCOperationDeadline(timeout: requestFrameTimeout)
        )
        let request = try CapabilityRPCCodec.decode(
            CapabilityRPCRequestEnvelope.self, from: requestFrame
        )
        let response = await raceHandlerAgainstPeer(
            descriptor: descriptor,
            request: request.request,
            handler: handler
        )
        guard let response else { return }
        try writeRPCFrame(
            CapabilityRPCResponseEnvelope(
                requestID: request.requestID,
                response: response
            ),
            to: descriptor,
            deadline: try RPCOperationDeadline(timeout: responseWriteTimeout)
        )
    } catch {
        // A malformed or disconnected peer is closed without retaining payloads.
    }
}

struct RPCOperationDeadline: Sendable {
    let instant: ContinuousClock.Instant

    init(timeout: Duration) throws {
        guard timeout > .zero, timeout <= .seconds(60) else {
            throw CapabilityRPCError.timedOut
        }
        instant = ContinuousClock().now.advanced(by: timeout)
    }

    func remainingMilliseconds() throws -> Int32 {
        let remaining = ContinuousClock().now.duration(to: instant)
        guard remaining > .zero else { throw CapabilityRPCError.timedOut }
        let components = remaining.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return Int32(max(1, min(Int64(Int32.max), milliseconds)))
    }
}

struct RPCFrameReader {
    private var buffered = Data()

    mutating func read(
        from descriptor: Int32,
        deadline: RPCOperationDeadline
    ) throws -> Data {
        while true {
            if Task.isCancelled { throw CancellationError() }
            if let newline = buffered.firstIndex(of: UInt8(ascii: "\n")) {
                let frame = Data(buffered[..<newline])
                buffered.removeSubrange(...newline)
                guard !frame.isEmpty else {
                    throw CapabilityRPCError.malformedFrame
                }
                guard frame.count <= CapabilityRPCCodec.maximumFrameBytes else {
                    throw CapabilityRPCError.frameTooLarge
                }
                return frame
            }
            guard buffered.count <= CapabilityRPCCodec.maximumFrameBytes else {
                throw CapabilityRPCError.frameTooLarge
            }
            try waitForRPCEvent(
                descriptor,
                events: Int16(POLLIN),
                deadline: deadline
            )
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count == 0 { throw CapabilityRPCError.peerDisconnected }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw CapabilityRPCError.peerDisconnected
            }
            buffered.append(contentsOf: bytes[..<count])
        }
    }
}

@discardableResult
private func waitForRPCEvent(
    _ descriptor: Int32,
    events: Int16,
    deadline: RPCOperationDeadline
) throws -> Int16 {
    while true {
        if Task.isCancelled { throw CancellationError() }
        var value = pollfd(fd: descriptor, events: events, revents: 0)
        let ready = poll(&value, 1, try deadline.remainingMilliseconds())
        if ready > 0 {
            if value.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw CapabilityRPCError.peerDisconnected
            }
            if value.revents & events != 0 { return value.revents }
            if value.revents & Int16(POLLHUP) != 0 {
                throw CapabilityRPCError.peerDisconnected
            }
        } else if ready == 0 {
            throw CapabilityRPCError.timedOut
        } else if errno != EINTR {
            throw CapabilityRPCError.peerDisconnected
        }
    }
}

private enum HandlerPeerRace: Sendable {
    case response(CapabilityRPCResponse)
    case peerDisconnected
}

private func raceHandlerAgainstPeer(
    descriptor: Int32,
    request: CapabilityRPCRequest,
    handler: @escaping CapabilityRPCHandler
) async -> CapabilityRPCResponse? {
    await withTaskGroup(of: HandlerPeerRace.self) { group in
        group.addTask { .response(await handler(request)) }
        group.addTask {
            await waitForPeerDisconnect(descriptor)
            return .peerDisconnected
        }
        guard let first = await group.next() else { return nil }
        group.cancelAll()
        switch first {
        case .response(let response): return response
        case .peerDisconnected: return nil
        }
    }
}

private func waitForPeerDisconnect(_ descriptor: Int32) async {
    while !Task.isCancelled {
        var value = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let ready = poll(&value, 1, 10)
        if ready > 0 {
            if value.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
            if value.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 { return }
                if count > 0 { return }
                if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    return
                }
            }
        } else if ready < 0 && errno != EINTR {
            return
        }
        await Task.yield()
    }
}

private func configureAcceptedSocket(_ descriptor: Int32) -> Bool {
    var noSignal: Int32 = 1
    return setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0
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
    var reader = RPCFrameReader()
    return try reader.read(
        from: descriptor,
        deadline: RPCOperationDeadline(timeout: .seconds(60))
    )
}

func writeRPCFrame<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    try writeRPCFrame(
        value,
        to: descriptor,
        deadline: RPCOperationDeadline(timeout: .seconds(60))
    )
}

func writeRPCFrame<T: Encodable>(
    _ value: T,
    to descriptor: Int32,
    deadline: RPCOperationDeadline
) throws {
    var data = try CapabilityRPCCodec.encode(value)
    data.append(UInt8(ascii: "\n"))
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            if Task.isCancelled { throw CancellationError() }
            try waitForRPCEvent(
                descriptor,
                events: Int16(POLLOUT),
                deadline: deadline
            )
            let count = send(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset,
                MSG_DONTWAIT
            )
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
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
