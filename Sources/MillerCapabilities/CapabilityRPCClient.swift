import Darwin
import Foundation
import MillerCore

public struct CapabilityRPCClient: Sendable {
    private let endpoint: CapabilityRPCEndpoint
    private let timeout: Duration

    public init(
        endpoint: CapabilityRPCEndpoint,
        timeout: Duration = .seconds(60)
    ) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    public init(
        socketURL: URL,
        token: CapabilityRPCSessionToken,
        timeout: Duration = .seconds(60)
    ) {
        self.init(
            endpoint: CapabilityRPCEndpoint(
                socketURL: socketURL,
                token: token,
                trustedParentURL: socketURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
            ),
            timeout: timeout
        )
    }

    public func send(_ request: CapabilityRPCRequest) async throws
        -> CapabilityRPCResponse
    {
        let operation = RPCDescriptorBox()
        return try await withTaskCancellationHandler {
            do {
                let response = try await Self.perform(
                    request,
                    endpoint: endpoint,
                    timeout: timeout,
                    descriptor: operation
                )
                try Task.checkCancellation()
                return response
            } catch where Task.isCancelled {
                throw CancellationError()
            }
        } onCancel: {
            operation.cancel()
        }
    }

    public func call(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data
    ) async throws -> CapabilityRPCResponse {
        let operation = RPCDescriptorBox()
        return try await withTaskCancellationHandler {
            do {
                let response = try await Self.perform(
                    .call(
                        callID,
                        capabilityID: capabilityID,
                        argumentsJSON: argumentsJSON
                    ),
                    endpoint: endpoint,
                    timeout: timeout,
                    descriptor: operation
                )
                try Task.checkCancellation()
                return response
            } catch where Task.isCancelled {
                throw CancellationError()
            }
        } onCancel: {
            operation.cancel()
            let endpoint = endpoint
            let timeout = min(timeout, .seconds(1))
            Task.detached {
                _ = try? await Self.perform(
                    .cancel(callID),
                    endpoint: endpoint,
                    timeout: timeout,
                    descriptor: RPCDescriptorBox()
                )
            }
        }
    }

    public func waitUntilEndpointUnavailable(
        pollInterval: Duration = .milliseconds(50)
    ) async {
        while !Task.isCancelled {
            var value = stat()
            guard lstat(endpoint.socketURL.path, &value) == 0,
                  (value.st_mode & S_IFMT) == S_IFSOCK,
                  value.st_uid == geteuid()
            else { return }
            do { try await Task.sleep(for: pollInterval) }
            catch { return }
        }
    }

    private static func perform(
        _ request: CapabilityRPCRequest,
        endpoint: CapabilityRPCEndpoint,
        timeout: Duration,
        descriptor descriptorBox: RPCDescriptorBox
    ) async throws -> CapabilityRPCResponse {
        let deadline = try RPCOperationDeadline(timeout: timeout)
        return try await Task.detached(priority: .userInitiated) {
            let descriptor = try makeRPCSocket()
            guard descriptorBox.install(descriptor) else {
                throw CancellationError()
            }
            defer { descriptorBox.finish(descriptor) }
            try connectRPCSocket(
                descriptor,
                to: endpoint.socketURL,
                deadline: deadline
            )

            try writeRPCFrame(
                CapabilityRPCAuthenticationFrame(token: endpoint.token),
                to: descriptor,
                deadline: deadline
            )
            let requestID = UUID()
            try writeRPCFrame(
                CapabilityRPCRequestEnvelope(
                    requestID: requestID,
                    request: request
                ),
                to: descriptor,
                deadline: deadline
            )
            var reader = RPCFrameReader()
            let frame = try reader.read(from: descriptor, deadline: deadline)
            let response = try CapabilityRPCCodec.decode(
                CapabilityRPCResponseEnvelope.self,
                from: frame
            )
            if response.response == .failed(nil, code: "authentication_failed") {
                throw CapabilityRPCError.authenticationFailed
            }
            guard response.requestID == requestID else {
                throw CapabilityRPCError.invalidRequestID
            }
            return response.response
        }.value
    }
}

final class RPCDescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private let shutdownDescriptor: @Sendable (Int32) -> Void
    private var descriptor: Int32 = -1
    private var cancelled = false

    init(
        shutdownDescriptor: @escaping @Sendable (Int32) -> Void = {
            _ = shutdown($0, SHUT_RDWR)
        }
    ) {
        self.shutdownDescriptor = shutdownDescriptor
    }

    func install(_ value: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            Darwin.close(value)
            return false
        }
        descriptor = value
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if descriptor >= 0 { shutdownDescriptor(descriptor) }
        lock.unlock()
    }

    func finish(_ value: Int32) {
        lock.lock()
        let owns = descriptor == value
        if owns { descriptor = -1 }
        lock.unlock()
        if owns { Darwin.close(value) }
    }
}

private func makeRPCSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CapabilityRPCError.socketFailure }
    do {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignal, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw CapabilityRPCError.socketFailure }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        else { throw CapabilityRPCError.socketFailure }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func connectRPCSocket(
    _ descriptor: Int32,
    to url: URL,
    deadline: RPCOperationDeadline
) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8CString)
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
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            )
        }
    }
    if result != 0 {
        guard errno == EINPROGRESS || errno == EAGAIN
                || errno == EWOULDBLOCK
        else { throw CapabilityRPCError.peerDisconnected }
        while true {
            if Task.isCancelled { throw CancellationError() }
            var value = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0
            )
            let ready = poll(
                &value,
                1,
                try deadline.remainingMilliseconds()
            )
            if ready == 0 { throw CapabilityRPCError.timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CapabilityRPCError.peerDisconnected
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &length
            ) == 0,
            socketError == 0 else {
                throw CapabilityRPCError.peerDisconnected
            }
            break
        }
    }
}
