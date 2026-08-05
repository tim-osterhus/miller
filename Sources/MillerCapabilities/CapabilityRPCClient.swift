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
            endpoint: CapabilityRPCEndpoint(socketURL: socketURL, token: token),
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

    private static func perform(
        _ request: CapabilityRPCRequest,
        endpoint: CapabilityRPCEndpoint,
        timeout: Duration,
        descriptor descriptorBox: RPCDescriptorBox
    ) async throws -> CapabilityRPCResponse {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = try connectRPCSocket(
                endpoint.socketURL,
                timeout: timeout
            )
            guard descriptorBox.install(descriptor) else {
                throw CancellationError()
            }
            defer { descriptorBox.finish(descriptor) }

            try writeRPCFrame(
                CapabilityRPCAuthenticationFrame(token: endpoint.token),
                to: descriptor
            )
            let requestID = UUID()
            try writeRPCFrame(
                CapabilityRPCRequestEnvelope(
                    requestID: requestID,
                    request: request
                ),
                to: descriptor
            )
            let frame = try readRPCFrame(from: descriptor)
            let response = try CapabilityRPCCodec.decode(
                CapabilityRPCResponseEnvelope.self,
                from: frame
            )
            guard response.requestID == requestID else {
                throw CapabilityRPCError.invalidRequestID
            }
            if response.response == .failed(nil, code: "authentication_failed") {
                throw CapabilityRPCError.authenticationFailed
            }
            return response.response
        }.value
    }
}

private final class RPCDescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

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
        let value = descriptor
        descriptor = -1
        lock.unlock()
        if value >= 0 {
            shutdown(value, SHUT_RDWR)
            Darwin.close(value)
        }
    }

    func finish(_ value: Int32) {
        lock.lock()
        let owns = descriptor == value
        if owns { descriptor = -1 }
        lock.unlock()
        if owns { Darwin.close(value) }
    }
}

private func connectRPCSocket(_ url: URL, timeout: Duration) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw CapabilityRPCError.socketFailure }
    do {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSignal, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw CapabilityRPCError.socketFailure }
        var timeval = try rpcTimeval(timeout)
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO,
            &timeval, socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO,
            &timeval, socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw CapabilityRPCError.socketFailure }

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
        guard result == 0 else {
            throw CapabilityRPCError.peerDisconnected
        }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func rpcTimeval(_ duration: Duration) throws -> timeval {
    guard duration > .zero, duration <= .seconds(60) else {
        throw CapabilityRPCError.timedOut
    }
    let components = duration.components
    let seconds = components.seconds
    let microseconds = components.attoseconds / 1_000_000_000_000
    return timeval(
        tv_sec: Int(seconds),
        tv_usec: Int32(max(1, microseconds))
    )
}
