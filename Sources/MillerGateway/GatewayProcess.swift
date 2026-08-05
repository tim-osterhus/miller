import Darwin
import Foundation

public final class GatewayProcess: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let workingDirectoryURL: URL
        public let environment: [String: String]
        public let terminationGrace: Duration

        public init(
            executableURL: URL,
            arguments: [String],
            workingDirectoryURL: URL,
            environment: [String: String],
            terminationGrace: Duration = .seconds(2)
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.workingDirectoryURL = workingDirectoryURL
            self.environment = environment
            self.terminationGrace = terminationGrace
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var pipes: [Pipe] = []
        var inputDescriptor: Int32?
        var inputOwner: FileHandle?
        var continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation?
        var reader = GatewayFrameReader()
        var stderrLineBytes = 0
        var stderrByteCount = 0
        var hasExited = true
        var stdoutReachedEOF = false

        func withLock<T>(_ operation: (State) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try operation(self)
        }
    }

    private final class ReadHandle: @unchecked Sendable {
        let descriptor: Int32

        init(_ value: FileHandle) {
            descriptor = value.fileDescriptor
        }
    }

    private static let environmentAllowlist = Set([
        "LANG", "LC_ALL", "TMPDIR", "TZ",
    ])

    private let configuration: Configuration
    private let state = State()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isRunning: Bool {
        state.withLock { $0.process != nil && !$0.hasExited }
    }

    public var stderrByteCount: Int {
        state.withLock(\.stderrByteCount)
    }

    public func start() throws -> AsyncThrowingStream<GatewayRecord, Error> {
        guard Set(configuration.environment.keys)
            .isSubset(of: Self.environmentAllowlist),
            FileManager.default.fileExists(
                atPath: configuration.workingDirectoryURL.path
            )
        else {
            throw GatewayProtocolError.processUnavailable
        }
        let alreadyStarted = state.withLock { $0.process != nil }
        guard !alreadyStarted else {
            throw GatewayProtocolError.invalidSequence
        }

        let child = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        child.executableURL = configuration.executableURL
        child.arguments = configuration.arguments
        child.currentDirectoryURL = configuration.workingDirectoryURL
        child.environment = configuration.environment
        child.standardInput = standardInput
        child.standardOutput = standardOutput
        child.standardError = standardError

        var captured: AsyncThrowingStream<GatewayRecord, Error>.Continuation?
        let stream = AsyncThrowingStream<GatewayRecord, Error> {
            captured = $0
        }
        do {
            try child.run()
        } catch {
            throw GatewayProtocolError.processUnavailable
        }
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        _ = setpgid(child.processIdentifier, child.processIdentifier)

        let foundationInput = standardInput.fileHandleForWriting
        let descriptor = foundationInput.fileDescriptor
        state.withLock {
            $0.process = child
            $0.pipes = [standardInput, standardOutput, standardError]
            $0.inputDescriptor = descriptor
            $0.inputOwner = foundationInput
            $0.continuation = captured
            $0.reader = GatewayFrameReader()
            $0.stderrByteCount = 0
            $0.stderrLineBytes = 0
            $0.hasExited = false
            $0.stdoutReachedEOF = false
        }

        let output = ReadHandle(standardOutput.fileHandleForReading)
        let error = ReadHandle(standardError.fileHandleForReading)
        Thread.detachNewThread { [self] in
            reap(child)
        }
        Thread.detachNewThread { [self] in
            pumpStdout(output, child: child)
        }
        Thread.detachNewThread { [self] in
            pumpStderr(error, child: child)
        }
        return stream
    }

    public func send(_ record: GatewayRecord) throws {
        let descriptor = try state.withLock {
            guard let descriptor = $0.inputDescriptor, $0.process != nil else {
                throw GatewayProtocolError.processUnavailable
            }
            return descriptor
        }
        let data = try GatewayFrameWriter().encode(record)
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw GatewayProtocolError.processUnavailable
                    }
                }
            }
        } catch {
            let child = state.withLock(\.process)
            if let child {
                Self.signalGroup(child, signal: SIGTERM)
            }
            throw GatewayProtocolError.processUnavailable
        }
    }

    public func closeInput() {
        let owner = state.withLock {
            $0.inputDescriptor = nil
            let owner = $0.inputOwner
            $0.inputOwner = nil
            return owner
        }
        try? owner?.close()
    }

    public func waitForExit() async throws {
        while isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func stop() async {
        closeInput()
        guard let child = state.withLock(\.process) else { return }
        if isRunning {
            Self.signalGroup(child, signal: SIGTERM)
            try? await Task.sleep(for: configuration.terminationGrace)
        }
        if isRunning {
            Self.signalGroup(child, signal: SIGKILL)
        }
        while isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let continuation: AsyncThrowingStream<GatewayRecord, Error>.Continuation? = state.withLock {
            guard $0.process === child else { return nil }
            $0.hasExited = true
            let continuation = $0.continuation
            $0.continuation = nil
            $0.process = nil
            $0.pipes.removeAll()
            return continuation
        }
        continuation?.finish()
    }

    private func pumpStdout(_ handle: ReadHandle, child: Process) {
        do {
            while true {
                let data = try Self.read(handle.descriptor, maximumCount: 65_536)
                if data.isEmpty { break }
                let (records, continuation): (
                    [GatewayRecord],
                    AsyncThrowingStream<GatewayRecord, Error>.Continuation?
                ) = try state.withLock {
                    guard $0.process === child else { return ([], nil) }
                    return (try $0.reader.consume(data), $0.continuation)
                }
                for record in records {
                    continuation?.yield(record)
                }
            }
            let isCurrent = try state.withLock {
                guard $0.process === child else { return false }
                try $0.reader.finish()
                $0.stdoutReachedEOF = true
                return true
            }
            if isCurrent {
                finishStreamAfterExitIfNeeded(child)
            }
        } catch let error as GatewayProtocolError {
            fail(error, child: child)
        } catch {
            fail(.processUnavailable, child: child)
        }
    }

    private func reap(_ child: Process) {
        child.waitUntilExit()
        let isCurrent = state.withLock {
            guard $0.process === child else { return false }
            $0.hasExited = true
            return true
        }
        if isCurrent {
            finishStreamAfterExitIfNeeded(child)
        }
    }

    private func finishStreamAfterExitIfNeeded(_ child: Process) {
        let completion: (
            AsyncThrowingStream<GatewayRecord, Error>.Continuation,
            Int32
        )? = state.withLock {
            guard $0.process === child,
                  $0.hasExited,
                  $0.stdoutReachedEOF,
                  let continuation = $0.continuation
            else {
                return nil
            }
            $0.continuation = nil
            return (continuation, child.terminationStatus)
        }
        guard let (continuation, status) = completion else { return }
        if status == 0 {
            continuation.finish()
        } else {
            continuation.finish(throwing: GatewayProtocolError.processUnavailable)
        }
    }

    private func pumpStderr(_ handle: ReadHandle, child: Process) {
        do {
            while true {
                let data = try Self.read(handle.descriptor, maximumCount: 4_096)
                if data.isEmpty { return }
                let isCurrent = try state.withLock {
                    guard $0.process === child else { return false }
                    for byte in data {
                        guard $0.stderrByteCount < 65_536 else {
                            throw GatewayProtocolError.recordTooLarge
                        }
                        $0.stderrByteCount += 1
                        if byte == 0x0a {
                            $0.stderrLineBytes = 0
                        } else {
                            $0.stderrLineBytes += 1
                            guard $0.stderrLineBytes <= 4_096 else {
                                throw GatewayProtocolError.recordTooLarge
                            }
                        }
                    }
                    return true
                }
                if !isCurrent { return }
            }
        } catch {
            fail(.recordTooLarge, child: child)
        }
    }

    private func fail(_ error: GatewayProtocolError, child: Process?) {
        let (continuation, activeChild): (
            AsyncThrowingStream<GatewayRecord, Error>.Continuation?,
            Process?
        ) = state.withLock {
            guard let child, $0.process === child
            else {
                return (nil, nil)
            }
            let continuation = $0.continuation
            $0.continuation = nil
            return (continuation, $0.hasExited ? nil : child)
        }
        continuation?.finish(throwing: error)
        if let activeChild {
            Self.signalGroup(activeChild, signal: SIGTERM)
        }
    }

    private static func signalGroup(_ child: Process, signal: Int32) {
        let pid = child.processIdentifier
        if Darwin.kill(-pid, signal) != 0 {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func read(
        _ descriptor: Int32,
        maximumCount: Int
    ) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        while true {
            let count = Darwin.read(descriptor, &buffer, maximumCount)
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count == 0 {
                return Data()
            }
            if errno != EINTR {
                throw GatewayProtocolError.processUnavailable
            }
        }
    }

}
