import Darwin
import Foundation
import Logging
import MCP

actor BoundedStdioTransport: Transport {
    nonisolated let logger = Logger(label: "miller.mcp.transport.stdio")

    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let maximumInboundBytes: Int
    private let failureHandler: @Sendable () -> Void
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var readTask: Task<Void, Never>?

    init(
        inputDescriptor: Int32,
        outputDescriptor: Int32,
        maximumInboundBytes: Int,
        failureHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.maximumInboundBytes = maximumInboundBytes
        self.failureHandler = failureHandler
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(4)
        ) { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        guard !connected else { return }
        try setNonBlocking(inputDescriptor)
        try setNonBlocking(outputDescriptor)
        connected = true
        readTask = Task { await readLoop() }
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        readTask?.cancel()
        readTask = nil
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPClientSessionError.notConnected }
        var framed = data
        framed.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < framed.count {
            try Task.checkCancellation()
            let written = framed.withUnsafeBytes { bytes in
                Darwin.write(
                    outputDescriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    framed.count - offset
                )
            }
            if written > 0 {
                offset += written
            } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try await Task.sleep(for: .milliseconds(2))
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                throw MCPClientSessionError.notConnected
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> { messageStream }

    private func readLoop() async {
        let readSize = max(1, min(4_096, maximumInboundBytes + 1))
        var buffer = [UInt8](repeating: 0, count: readSize)
        var pending = Data()
        while connected && !Task.isCancelled {
            let count = Darwin.read(inputDescriptor, &buffer, buffer.count)
            if count > 0 {
                pending.append(contentsOf: buffer.prefix(count))
                do {
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let frame = pending[..<newline]
                        guard frame.count <= maximumInboundBytes else {
                            throw MCPClientSessionError.inboundTooLarge
                        }
                        pending.removeSubrange(...newline)
                        if !frame.isEmpty {
                            switch continuation.yield(Data(frame)) {
                            case .enqueued: break
                            case .dropped: throw MCPClientSessionError.inboundTooLarge
                            case .terminated: return
                            @unknown default: throw MCPClientSessionError.inboundTooLarge
                            }
                        }
                    }
                    guard pending.count <= maximumInboundBytes else {
                        throw MCPClientSessionError.inboundTooLarge
                    }
                } catch {
                    connected = false
                    failureHandler()
                    continuation.finish(throwing: error)
                    return
                }
            } else if count == 0 {
                connected = false
                failureHandler()
                continuation.finish(throwing: MCPClientSessionError.connectionClosed)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(for: .milliseconds(2))
            } else if errno != EINTR {
                connected = false
                failureHandler()
                continuation.finish(throwing: MCPClientSessionError.notConnected)
                return
            }
        }
    }

    private func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw MCPClientSessionError.notConnected
        }
    }
}

enum MCPHTTPTransportPolicy {
    static func ephemeralConfiguration(
        protocolClasses: [AnyClass]? = nil
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache?.removeAllCachedResponses()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    static func redirectedRequest(_ proposed: URLRequest) -> URLRequest? { nil }
}

private final class MCPNoRedirectSessionDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(MCPHTTPTransportPolicy.redirectedRequest(request))
    }
}

actor BoundedHTTPTransport: Transport {
    nonisolated let logger = Logger(label: "miller.mcp.transport.http")

    private let endpoint: URL
    private let headers: [String: String]
    private let maximumInboundBytes: Int
    private let delegate: MCPNoRedirectSessionDelegate
    private let session: URLSession
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var sessionID: String?
    private var protocolVersion = Version.latest
    private var initializeRequestID: String?

    init(
        endpoint: URL,
        headers: [String: String],
        maximumInboundBytes: Int,
        configuration: URLSessionConfiguration =
            MCPHTTPTransportPolicy.ephemeralConfiguration()
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.maximumInboundBytes = maximumInboundBytes
        let delegate = MCPNoRedirectSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil
        )
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(4)
        ) { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws { connected = true }

    func disconnect() async {
        guard connected else { return }
        connected = false
        session.invalidateAndCancel()
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPClientSessionError.notConnected }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "application/json, text/event-stream", forHTTPHeaderField: "Accept"
        )
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        }
        observeOutbound(data)

        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { throw MCPClientSessionError.notConnected }
        if response.expectedContentLength > Int64(maximumInboundBytes) {
            throw MCPClientSessionError.inboundTooLarge
        }
        if let value = response.value(forHTTPHeaderField: "MCP-Session-Id") {
            sessionID = value
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.lowercased().contains("text/event-stream") {
            var parser = BoundedSSEParser(limit: maximumInboundBytes)
            for try await byte in bytes {
                for message in try parser.consume(byte) {
                    try yield(message)
                }
            }
            if let message = try parser.finish() { try yield(message) }
        } else {
            var body = Data()
            body.reserveCapacity(min(maximumInboundBytes, 64 * 1_024))
            for try await byte in bytes {
                guard body.count < maximumInboundBytes else {
                    throw MCPClientSessionError.inboundTooLarge
                }
                body.append(byte)
            }
            if !body.isEmpty { try yield(body) }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> { messageStream }

    private func yield(_ data: Data) throws {
        observeInbound(data)
        switch continuation.yield(data) {
        case .enqueued: return
        case .dropped: throw MCPClientSessionError.inboundTooLarge
        case .terminated: throw MCPClientSessionError.notConnected
        @unknown default: throw MCPClientSessionError.inboundTooLarge
        }
    }

    private func observeOutbound(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["method"] as? String == "initialize",
              let id = Self.rpcID(object["id"])
        else { return }
        initializeRequestID = id
    }

    private func observeInbound(_ data: Data) {
        guard let initializeRequestID,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Self.rpcID(object["id"]) == initializeRequestID,
              let result = object["result"] as? [String: Any],
              let version = result["protocolVersion"] as? String
        else { return }
        protocolVersion = version
        self.initializeRequestID = nil
    }

    private static func rpcID(_ value: Any?) -> String? {
        if let value = value as? String { return "s:\(value)" }
        if let value = value as? NSNumber { return "n:\(value.stringValue)" }
        return nil
    }
}

private struct BoundedSSEParser {
    let limit: Int
    private var line = Data()
    private var event = Data()

    init(limit: Int) { self.limit = limit }

    mutating func consume(_ byte: UInt8) throws -> [Data] {
        if byte == UInt8(ascii: "\n") {
            let message = try finishLine()
            return message.map { [$0] } ?? []
        }
        guard line.count < limit else { throw MCPClientSessionError.inboundTooLarge }
        line.append(byte)
        return []
    }

    mutating func finish() throws -> Data? {
        if !line.isEmpty { _ = try finishLine() }
        return flushEvent()
    }

    private mutating func finishLine() throws -> Data? {
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return flushEvent() }
        guard line.starts(with: Data("data:".utf8)) else { return nil }
        var value = line.dropFirst(5)
        if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        guard event.count + value.count + 1 <= limit else {
            throw MCPClientSessionError.inboundTooLarge
        }
        event.append(value)
        event.append(UInt8(ascii: "\n"))
        return nil
    }

    private mutating func flushEvent() -> Data? {
        guard !event.isEmpty else { return nil }
        if event.last == UInt8(ascii: "\n") { event.removeLast() }
        defer { event.removeAll(keepingCapacity: true) }
        return event
    }
}
