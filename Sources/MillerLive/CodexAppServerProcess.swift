import Darwin
import Foundation

public enum LiveProcessError: Error, Equatable, Sendable {
    case invalidConfiguration
    case processUnavailable
    case invalidFrame
    case helperExited
    case timeout
}

public final class CodexAppServerProcess: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let arguments: [String]
        public let temporaryParentURL: URL
        public let temporaryRootURL: URL
        public let environment: [String: String]
        public let terminationGrace: Duration
        public let cleanupPendingDelay: Duration
        public let spawnedProcessVerifier: @Sendable (pid_t) throws -> Void
        let realtimeFeatureConfig: Data?

        public init(
            executableURL: URL,
            arguments: [String],
            temporaryParentURL: URL,
            terminationGrace: Duration = .seconds(2),
            cleanupPendingDelay: Duration = .seconds(2),
            additionalEnvironment: [String: String] = [:],
            spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void = { _ in }
        ) throws {
            try self.init(
                executableURL: executableURL,
                arguments: arguments,
                temporaryParentURL: temporaryParentURL,
                terminationGrace: terminationGrace,
                cleanupPendingDelay: cleanupPendingDelay,
                additionalEnvironment: additionalEnvironment,
                spawnedProcessVerifier: spawnedProcessVerifier,
                testRealtimeFeatureConfig: Data(
                    """
                    [features]
                    realtime_conversation = true

                    [realtime]
                    version = "v1"

                    """.utf8
                )
            )
        }

        init(
            executableURL: URL,
            arguments: [String],
            temporaryParentURL: URL,
            terminationGrace: Duration = .seconds(2),
            cleanupPendingDelay: Duration = .seconds(2),
            additionalEnvironment: [String: String] = [:],
            spawnedProcessVerifier: @escaping @Sendable (pid_t) throws -> Void = { _ in },
            testRealtimeFeatureConfig: Data?
        ) throws {
            guard executableURL.isFileURL, executableURL.baseURL == nil,
                  executableURL.path.hasPrefix("/"), temporaryParentURL.isFileURL,
                  temporaryParentURL.path.hasPrefix("/")
            else { throw LiveProcessError.invalidConfiguration }
            let root = temporaryParentURL.appendingPathComponent(
                "gpt-live-process.\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            self.executableURL = executableURL
            self.arguments = arguments
            self.temporaryParentURL = temporaryParentURL
            temporaryRootURL = root
            self.terminationGrace = terminationGrace
            self.cleanupPendingDelay = cleanupPendingDelay
            self.spawnedProcessVerifier = spawnedProcessVerifier
            realtimeFeatureConfig = testRealtimeFeatureConfig
            let baseline = [
                "HOME": root.path,
                "CODEX_HOME": root.appendingPathComponent("codex-home").path,
                "TMPDIR": root.appendingPathComponent("tmp").path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "NO_COLOR": "1",
            ]
            let reserved = Set(baseline.keys)
            guard additionalEnvironment.count <= 16,
                  additionalEnvironment.allSatisfy({ key, value in
                      !reserved.contains(key)
                          && !key.isEmpty && key.utf8.count <= 128
                          && key.unicodeScalars.first.map {
                              $0.value == 95 || (65...90).contains($0.value)
                          } == true
                          && key.unicodeScalars.allSatisfy {
                              $0.value == 95 || (65...90).contains($0.value)
                                  || (48...57).contains($0.value)
                          }
                          && value.utf8.count <= 4_096
                          && !value.utf8.contains(0)
                  })
            else { throw LiveProcessError.invalidConfiguration }
            environment = baseline.merging(additionalEnvironment) { current, _ in current }
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let transportLock = NSLock()
        var pid: pid_t?
        var input: Int32?
        var output: Int32?
        var error: Int32?
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        var buffer = Data()
        var running = false
        var exitStatus: Int32?
        var terminationRequested = false
        var cleanupPendingReported = false

        func locked<T>(_ body: (State) throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body(self)
        }
    }

    private let configuration: Configuration
    private let state = State()

    public init(configuration: Configuration) { self.configuration = configuration }

    deinit {
        cancel()
        let deadline = Date().addingTimeInterval(1)
        while state.locked(\.running), Date() < deadline { usleep(10_000) }
        if let pid = state.locked(\.pid) { Self.signalGroup(pid, signal: SIGKILL) }
    }

    public var temporaryRootURL: URL { configuration.temporaryRootURL }
    public var isRunning: Bool { state.locked(\.running) }
    var inputSuppressesSIGPIPE: Bool {
        state.transportLock.lock(); defer { state.transportLock.unlock() }
        guard let descriptor = state.locked(\.input) else { return false }
        return fcntl(descriptor, F_GETNOSIGPIPE) == 1
    }

    public func start() throws -> AsyncThrowingStream<Data, Error> {
        guard !isRunning,
              FileManager.default.isExecutableFile(atPath: configuration.executableURL.path)
        else { throw LiveProcessError.processUnavailable }
        try preparePrivateRoot()

        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&stdinPipe) == 0, Darwin.pipe(&stdoutPipe) == 0,
              Darwin.pipe(&stderrPipe) == 0
        else {
            Self.closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            removePrivateRoot()
            throw LiveProcessError.processUnavailable
        }
        guard fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1) == 0 else {
            Self.closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            removePrivateRoot()
            throw LiveProcessError.processUnavailable
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        for descriptor in stdinPipe + stdoutPipe + stderrPipe {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawn_file_actions_addchdir_np(&actions, configuration.temporaryRootURL.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let argv = [configuration.executableURL.path] + configuration.arguments
        let env = configuration.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let result = Self.withCStringArray(argv) { argvPointers in
            Self.withCStringArray(env) { envPointers in
                posix_spawn(
                    &pid, configuration.executableURL.path,
                    &actions, &attributes, argvPointers, envPointers
                )
            }
        }
        guard result == 0 else {
            Self.closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            removePrivateRoot()
            throw LiveProcessError.processUnavailable
        }
        // The parent no longer needs its copies of the child's pipe ends.
        // Close them before authenticating the child PID so rejection cleanup
        // cannot retain a second descriptor path into the helper.
        Darwin.close(stdinPipe[0]); stdinPipe[0] = -1
        Darwin.close(stdoutPipe[1]); stdoutPipe[1] = -1
        Darwin.close(stderrPipe[1]); stderrPipe[1] = -1
        do {
            try configuration.spawnedProcessVerifier(pid)
        } catch {
            Self.signalGroup(pid, signal: SIGKILL)
            Self.reapRejectedProcess(pid)
            Self.closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            removePrivateRoot()
            throw LiveProcessError.processUnavailable
        }

        _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutPipe[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(stderrPipe[0], F_SETFD, FD_CLOEXEC)
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(8)) {
            captured = $0
        }
        state.locked {
            $0.pid = pid; $0.input = stdinPipe[1]; $0.output = stdoutPipe[0]
            $0.error = stderrPipe[0]; $0.continuation = captured
            $0.buffer = Data(); $0.running = true; $0.exitStatus = nil
            $0.terminationRequested = false; $0.cleanupPendingReported = false
        }
        let state = self.state
        let root = configuration.temporaryRootURL
        let parent = configuration.temporaryParentURL
        let outputDescriptor = stdoutPipe[0]
        let errorDescriptor = stderrPipe[0]
        let spawnedPID = pid
        Thread.detachNewThread { Self.pump(outputDescriptor, pid: spawnedPID, state: state) }
        Thread.detachNewThread { Self.drain(errorDescriptor) }
        Thread.detachNewThread { Self.reap(spawnedPID, state: state, root: root, parent: parent) }
        return stream
    }

    public func send(_ data: Data) throws {
        state.transportLock.lock(); defer { state.transportLock.unlock() }
        guard data.count <= 1_048_576,
              let descriptor = state.locked({ $0.running ? $0.input : nil })
        else { throw LiveProcessError.processUnavailable }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0, errno == EINTR { continue }
                else { throw LiveProcessError.processUnavailable }
            }
        }
    }

    public func closeInput() {
        state.transportLock.lock(); defer { state.transportLock.unlock() }
        let descriptor = state.locked { value -> Int32? in
            defer { value.input = nil }
            return value.input
        }
        if let descriptor { Darwin.close(descriptor) }
    }

    public func cancel() {
        closeInput()
        let pid = state.locked { value -> pid_t? in
            value.terminationRequested = true
            return value.pid
        }
        if let pid { Self.signalGroup(pid, signal: SIGTERM) }
    }

    public func waitForTermination(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isRunning {
            guard ContinuousClock.now < deadline else { throw LiveProcessError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func waitForExit(timeout: Duration) async throws {
        try await waitForTermination(timeout: timeout)
        guard state.locked(\.exitStatus) == 0 else { throw LiveProcessError.helperExited }
    }

    public func stop(
        onCleanupPending: @escaping @Sendable () async -> Void = {}
    ) async {
        let pendingDeadline = ContinuousClock.now.advanced(
            by: configuration.cleanupPendingDelay
        )
        cancel()
        let graceDeadline = ContinuousClock.now.advanced(by: configuration.terminationGrace)
        while isRunning, ContinuousClock.now < graceDeadline {
            await reportCleanupPendingIfNeeded(
                deadline: pendingDeadline,
                onCleanupPending: onCleanupPending
            )
            await Self.sleepIgnoringCancellation(for: .milliseconds(10))
        }
        if let pid = state.locked(\.pid), isRunning {
            Self.signalGroup(pid, signal: SIGKILL)
        }
        while isRunning {
            await reportCleanupPendingIfNeeded(
                deadline: pendingDeadline,
                onCleanupPending: onCleanupPending
            )
            await Self.sleepIgnoringCancellation(for: .milliseconds(10))
        }
        while FileManager.default.fileExists(atPath: configuration.temporaryRootURL.path) {
            _ = removePrivateRoot()
            guard FileManager.default.fileExists(atPath: configuration.temporaryRootURL.path)
            else { break }
            await reportCleanupPendingIfNeeded(
                deadline: pendingDeadline,
                onCleanupPending: onCleanupPending
            )
            await Self.sleepIgnoringCancellation(for: .milliseconds(10))
        }
    }

    private func reportCleanupPendingIfNeeded(
        deadline: ContinuousClock.Instant,
        onCleanupPending: @escaping @Sendable () async -> Void
    ) async {
        guard ContinuousClock.now >= deadline else { return }
        let shouldReport = state.locked { value in
            guard !value.cleanupPendingReported else { return false }
            value.cleanupPendingReported = true
            return true
        }
        if shouldReport { await onCleanupPending() }
    }

    private func preparePrivateRoot() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: configuration.temporaryParentURL, withIntermediateDirectories: true)
            for directory in [
                configuration.temporaryRootURL,
                configuration.temporaryRootURL.appendingPathComponent("codex-home"),
                configuration.temporaryRootURL.appendingPathComponent("tmp"),
            ] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                guard chmod(directory.path, 0o700) == 0 else { throw LiveProcessError.processUnavailable }
            }
            if let featureBytes = configuration.realtimeFeatureConfig {
                let featureConfig = configuration.temporaryRootURL
                    .appendingPathComponent("codex-home/config.toml")
                try featureBytes.write(to: featureConfig, options: .withoutOverwriting)
                guard chmod(featureConfig.path, 0o600) == 0 else {
                    throw LiveProcessError.processUnavailable
                }
            }
        } catch {
            _ = removePrivateRoot()
            throw error
        }
    }

    @discardableResult
    private func removePrivateRoot() -> Bool {
        Self.removePrivateRoot(
            configuration.temporaryRootURL,
            parent: configuration.temporaryParentURL
        )
    }

    private static func pump(_ descriptor: Int32, pid: pid_t, state: State) {
        defer { Darwin.close(descriptor) }
        do {
            while true {
                let chunk = try read(descriptor, maximumCount: 65_536)
                if chunk.isEmpty { break }
                let frames = try state.locked { value -> [Data] in
                    guard value.pid == pid else { return [] }
                    value.buffer.append(chunk)
                    guard value.buffer.count <= 1_048_576 else { throw LiveProcessError.invalidFrame }
                    var frames: [Data] = []
                    while let newline = value.buffer.firstIndex(of: 0x0A) {
                        frames.append(value.buffer.prefix(upTo: newline))
                        value.buffer.removeSubrange(...newline)
                    }
                    return frames
                }
                guard let continuation = state.locked(\.continuation) else { return }
                for frame in frames {
                    switch continuation.yield(frame) {
                    case .enqueued: break
                    case .dropped: throw LiveProcessError.invalidFrame
                    case .terminated: return
                    @unknown default: throw LiveProcessError.invalidFrame
                    }
                }
            }
        } catch {
            state.locked(\.continuation)?.finish(throwing: error)
            signalGroup(pid, signal: SIGTERM)
        }
    }

    private static func drain(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        while let chunk = try? read(descriptor, maximumCount: 4096), !chunk.isEmpty {}
    }

    private static func reap(_ pid: pid_t, state: State, root: URL, parent: URL) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        signalGroup(pid, signal: SIGTERM)
        usleep(50_000)
        signalGroup(pid, signal: SIGKILL)
        let terminationSignal = status & 0x7f
        let exitCode: Int32 = terminationSignal == 0
            ? (status >> 8) & 0xff
            : 128 + terminationSignal
        _ = removePrivateRoot(root, parent: parent)
        state.transportLock.lock()
        let (continuation, requested) = state.locked {
            value -> (AsyncThrowingStream<Data, Error>.Continuation?, Bool) in
            guard value.pid == pid else { return (nil, value.terminationRequested) }
            if let input = value.input { Darwin.close(input) }
            value.input = nil; value.output = nil; value.error = nil
            value.pid = nil; value.running = false; value.exitStatus = exitCode
            let continuation = value.continuation; value.continuation = nil
            return (continuation, value.terminationRequested)
        }
        state.transportLock.unlock()
        if exitCode == 0 || requested { continuation?.finish() }
        else { continuation?.finish(throwing: LiveProcessError.helperExited) }
    }

    private static func removePrivateRoot(_ root: URL, parent: URL) -> Bool {
        guard root.path.hasPrefix(parent.path + "/gpt-live-process."), !root.path.isEmpty,
              root.path != "/" else { return false }
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        do {
            try FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        } catch {
            return false
        }
    }

    private static func signalGroup(_ pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        if Darwin.kill(-pid, signal) != 0, errno != ESRCH { _ = Darwin.kill(pid, signal) }
    }

    private static func reapRejectedProcess(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    }

    private static func sleepIgnoringCancellation(for duration: Duration) async {
        await Task.detached {
            try? await Task.sleep(for: duration)
        }.value
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) }
    }

    private static func withCStringArray<T>(
        _ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    private static func read(_ descriptor: Int32, maximumCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumCount)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            throw LiveProcessError.processUnavailable
        }
    }
}
