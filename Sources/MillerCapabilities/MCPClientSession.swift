import Foundation
import Darwin
import MCP
import MillerCore

public enum MCPClientSessionError: Error, Equatable, Sendable {
    case notConnected
    case startupTimedOut
    case callTimedOut
    case invalidArguments
    case argumentsTooLarge
    case tooManyTools
    case schemaTooLarge
    case invalidTool
    case processLaunchFailed
}

public struct MCPDiscoveredTool: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let summary: String
    public let inputSchemaJSON: Data
    public let readOnlyHint: Bool?

    public init(
        name: String,
        displayName: String,
        summary: String,
        inputSchemaJSON: Data,
        readOnlyHint: Bool?
    ) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnlyHint = readOnlyHint
    }
}

public struct MCPToolCallResult: Equatable, Sendable {
    public let contentJSON: Data
    public let isError: Bool

    public init(contentJSON: Data, isError: Bool) {
        self.contentJSON = contentJSON
        self.isError = isError
    }
}

public protocol MCPClientSessionProtocol: Actor {
    nonisolated var serverID: String { get }
    func listTools() async throws -> [MCPDiscoveredTool]
    func callTool(name: String, argumentsJSON: Data) async throws -> MCPToolCallResult
    func disconnect() async
}

public typealias MCPCredentialResolver = @Sendable (UUID) async throws -> String

public actor MCPClientSession: MCPClientSessionProtocol {
    public nonisolated let serverID: String

    private let configuration: MCPServerConfiguration
    private let client: Client
    private let processResources: StdioProcessResources?
    private var connected = true

    private init(
        configuration: MCPServerConfiguration,
        client: Client,
        processResources: StdioProcessResources?
    ) {
        self.serverID = configuration.id
        self.configuration = configuration
        self.client = client
        self.processResources = processResources
    }

    public static func connect(
        configuration: MCPServerConfiguration,
        credentialResolver: @escaping MCPCredentialResolver
    ) async throws -> MCPClientSession {
        let client = Client(
            name: "miller", version: "0.1.1", configuration: .strict
        )
        let resources: StdioProcessResources?
        let transport: any Transport

        switch configuration.transport {
        case .stdio(let executable, let arguments):
            let environment = try await resolvedEnvironment(
                configuration.secrets, resolver: credentialResolver
            )
            let stdio = try StdioProcessResources(
                executable: executable,
                arguments: arguments,
                environment: environment,
                stderrLimit: configuration.bounds.maximumStderrBytes
            )
            do {
                try stdio.run()
            } catch {
                stdio.terminate()
                throw MCPClientSessionError.processLaunchFailed
            }
            resources = stdio
            transport = StdioTransport(
                input: .init(rawValue: stdio.stdoutReadDescriptor),
                output: .init(rawValue: stdio.stdinWriteDescriptor)
            )
        case .http(let endpoint):
            let headers = try await resolvedHeaders(
                configuration.secrets, resolver: credentialResolver
            )
            resources = nil
            transport = HTTPClientTransport(
                endpoint: endpoint,
                sseInitializationTimeout: configuration.bounds.startupTimeout.timeInterval,
                requestModifier: { request in
                    var request = request
                    for (name, value) in headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    return request
                }
            )
        }

        do {
            _ = try await boundedAsync(
                timeout: configuration.bounds.startupTimeout,
                timeoutError: MCPClientSessionError.startupTimedOut
            ) {
                try await client.connect(transport: transport)
            }
            return MCPClientSession(
                configuration: configuration,
                client: client,
                processResources: resources
            )
        } catch {
            await client.disconnect()
            resources?.terminate()
            throw error
        }
    }

    public func listTools() async throws -> [MCPDiscoveredTool] {
        guard connected else { throw MCPClientSessionError.notConnected }
        var cursor: String?
        var seenCursors = Set<String>()
        var discovered: [MCPDiscoveredTool] = []
        repeat {
            let pageCursor = cursor
            let page = try await boundedAsync(
                timeout: configuration.bounds.callTimeout,
                timeoutError: MCPClientSessionError.callTimedOut
            ) {
                try await self.client.listTools(cursor: pageCursor)
            }
            guard discovered.count + page.tools.count <= configuration.bounds.maximumTools else {
                throw MCPClientSessionError.tooManyTools
            }
            for tool in page.tools {
                let schema = try JSONEncoder().encode(tool.inputSchema)
                guard schema.count <= configuration.bounds.maximumSchemaBytes else {
                    throw MCPClientSessionError.schemaTooLarge
                }
                _ = try CapabilityID(
                    source: .millerMCP,
                    serverID: serverID,
                    toolName: tool.name
                )
                let displayName = bounded(tool.title ?? tool.name, bytes: 256)
                let summary = bounded(tool.description ?? displayName, bytes: 1_024)
                discovered.append(MCPDiscoveredTool(
                    name: tool.name,
                    displayName: displayName,
                    summary: summary,
                    inputSchemaJSON: schema,
                    readOnlyHint: tool.annotations.readOnlyHint
                ))
            }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw MCPClientSessionError.tooManyTools
            }
        } while cursor != nil
        return discovered
    }

    public func callTool(
        name: String,
        argumentsJSON: Data
    ) async throws -> MCPToolCallResult {
        guard connected else { throw MCPClientSessionError.notConnected }
        guard argumentsJSON.count <= configuration.bounds.maximumArgumentBytes else {
            throw MCPClientSessionError.argumentsTooLarge
        }
        guard let object = try? JSONDecoder().decode(
            [String: Value].self, from: argumentsJSON
        ) else { throw MCPClientSessionError.invalidArguments }

        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name, arguments: object
        )
        let result: CallTool.Result = try await boundedAsync(
            timeout: configuration.bounds.callTimeout,
            timeoutError: MCPClientSessionError.callTimedOut,
            onCancel: {
                try? await self.client.cancelRequest(
                    context.requestID, reason: "Miller call ended"
                )
            }
        ) {
            try await context.value
        }
        let content = try JSONEncoder().encode(
            ToolResultProjection(
                content: result.content,
                structuredContent: result.structuredContent,
                isError: result.isError ?? false
            )
        )
        let boundedResult = try CapabilityResultSanitizer(
            maximumResultBytes: configuration.bounds.maximumResultBytes
        ).project(contentJSON: content, isError: result.isError ?? false)
        return MCPToolCallResult(
            contentJSON: boundedResult.contentJSON,
            isError: boundedResult.isError
        )
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        await client.disconnect()
        processResources?.terminate()
    }

    private static func resolvedEnvironment(
        _ bindings: [MCPSecretBinding],
        resolver: MCPCredentialResolver
    ) async throws -> [String: String] {
        var environment = safeBaseEnvironment(
            from: ProcessInfo.processInfo.environment
        )
        for binding in bindings where binding.destination == .environment {
            environment[binding.name] = try await resolver(binding.credentialReference)
        }
        return environment
    }

    static func safeBaseEnvironment(
        from source: [String: String]
    ) -> [String: String] {
        let allowed = ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"]
        return Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            source[key].map { (key, $0) }
        })
    }

    private static func resolvedHeaders(
        _ bindings: [MCPSecretBinding],
        resolver: MCPCredentialResolver
    ) async throws -> [String: String] {
        var headers: [String: String] = [:]
        for binding in bindings where binding.destination == .header {
            headers[binding.name] = try await resolver(binding.credentialReference)
        }
        return headers
    }
}

private struct ToolResultProjection: Encodable {
    let content: [Tool.Content]
    let structuredContent: Value?
    let isError: Bool
}

private func bounded(_ text: String, bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var result = ""
    result.reserveCapacity(bytes)
    for scalar in text.unicodeScalars {
        let candidate = result + String(scalar)
        guard candidate.utf8.count <= bytes else { break }
        result = candidate
    }
    return result
}

private final class StdioProcessResources: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stderrBuffer: BoundedByteBuffer
    private let lock = NSLock()
    private var didTerminate = false

    var stdoutReadDescriptor: Int32 {
        stdoutPipe.fileHandleForReading.fileDescriptor
    }
    var stdinWriteDescriptor: Int32 {
        stdinPipe.fileHandleForWriting.fileDescriptor
    }

    init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        stderrLimit: Int
    ) throws {
        stderrBuffer = BoundedByteBuffer(limit: stderrLimit)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let buffer = stderrBuffer
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
    }

    func run() throws { try process.run() }

    func terminate() {
        lock.lock()
        guard !didTerminate else {
            lock.unlock()
            return
        }
        didTerminate = true
        lock.unlock()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    deinit { terminate() }
}

private final class BoundedByteBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    init(limit: Int) { self.limit = limit }
    func append(_ incoming: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(incoming.prefix(limit - data.count))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}

func boundedAsync<T: Sendable>(
    timeout: Duration,
    timeoutError: any Error & Sendable,
    onCancel: @escaping @Sendable () async -> Void = {},
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let state = AsyncRaceState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
            let operationTask = Task {
                do { state.resolve(.success(try await operation())) }
                catch { state.resolve(.failure(error)) }
            }
            state.setOperationTask(operationTask)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                    if state.resolve(.failure(timeoutError)) {
                        operationTask.cancel()
                        await onCancel()
                    }
                } catch {}
            }
            state.setTimeoutTask(timeoutTask)
        }
    } onCancel: {
        if state.resolve(.failure(CancellationError())) {
            state.cancelTasks()
            Task { await onCancel() }
        }
    }
}

private final class AsyncRaceState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var finished = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result = pendingResult {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = continuation
        if continuation == nil { pendingResult = result }
        let operation = operationTask
        let timeout = timeoutTask
        lock.unlock()
        continuation?.resume(with: result)
        operation?.cancel()
        timeout?.cancel()
        return true
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        lock.lock()
        operationTask = task
        let shouldCancel = finished
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        timeoutTask = task
        let shouldCancel = finished
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancelTasks() {
        lock.lock()
        let operation = operationTask
        let timeout = timeoutTask
        lock.unlock()
        operation?.cancel()
        timeout?.cancel()
    }
}
