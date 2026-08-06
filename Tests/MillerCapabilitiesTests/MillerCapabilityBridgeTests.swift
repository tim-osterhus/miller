import Darwin
import Foundation
import MCP
@testable import MillerCapabilities
@testable import MillerCapabilityBridge
import MillerCore
import Testing

@Suite(.serialized)
struct MillerCapabilityBridgeTests {
    @Test
    func projectsBrokerCatalogAndForwardsCallsOverRPC() async throws {
        let trustedParent = try bridgeTrustedParent(prefix: "miller-bridge-test")
        defer { try? FileManager.default.removeItem(at: trustedParent) }
        let profileID = UUID()
        let descriptor = try makeBridgeDescriptor(profileID: profileID)
        let callProbe = BridgeCallProbe()
        let rpcServer = CapabilityRPCServer(trustedParent: trustedParent) { request in
            switch request {
            case .list(let receivedProfileID):
                return receivedProfileID == profileID
                    ? .catalog([descriptor])
                    : .failed(nil, code: "profile_mismatch")
            case .call(let callID, let capabilityID, let argumentsJSON):
                await callProbe.record(
                    callID: callID,
                    capabilityID: capabilityID,
                    argumentsJSON: argumentsJSON
                )
                return .result(
                    callID,
                    contentJSON: Data(
                        #"{"content":[{"type":"text","text":"bridge-ok"}],"isError":false}"#.utf8
                    ),
                    isError: false
                )
            case .cancel(let callID):
                return .failed(callID, code: "cancelled")
            }
        }
        let endpoint = try await rpcServer.start()

        let runtime = MillerCapabilityBridgeRuntime(
            rpcClient: CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1)),
            providerProfileID: profileID
        )
        let server = await runtime.makeServer()
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transports.server)
        let client = Client(
            name: "bridge-test", version: "1.0", configuration: .strict
        )
        _ = try await client.connect(transport: transports.client)

        let tools = try await client.listTools().tools
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.name.hasPrefix("miller_"))
        #expect(tool.title == "Lookup")
        #expect(tool.description == "Looks up a value")
        #expect(tool.annotations.readOnlyHint == true)

        let result = try await client.callTool(
            name: tool.name,
            arguments: ["query": .string("value")]
        ).value
        #expect(result.isError == false)
        #expect(result.content == [
            .text(text: "bridge-ok", annotations: nil, _meta: nil),
        ])
        #expect(await callProbe.capabilityID == descriptor.id)
        #expect(await callProbe.argumentsJSON != nil)

        await client.disconnect()
        await server.stop()
        await rpcServer.stop()
    }

    @Test
    func rejectsMissingOrInvalidProcessLifetimeConfiguration() throws {
        #expect(throws: MillerCapabilityBridgeError.invalidEnvironment) {
            _ = try MillerCapabilityBridgeRuntime(environment: [:])
        }
        #expect(throws: MillerCapabilityBridgeError.invalidEnvironment) {
            _ = try MillerCapabilityBridgeRuntime(environment: [
                CapabilityRPCEnvironment.socketPath: "/tmp/socket",
                CapabilityRPCEnvironment.sessionToken: "not-a-token",
                CapabilityRPCEnvironment.providerProfileID: UUID().uuidString,
                CapabilityRPCEnvironment.trustedParent: "/tmp",
            ])
        }
    }

    @Test
    func unknownProjectedToolIsRejectedWithoutRPCExecution() async throws {
        let trustedParent = try bridgeTrustedParent(prefix: "miller-bridge-unknown")
        defer { try? FileManager.default.removeItem(at: trustedParent) }
        let profileID = UUID()
        let rpcServer = CapabilityRPCServer(trustedParent: trustedParent) { request in
            switch request {
            case .list: .catalog([])
            case .call(let callID, _, _): .failed(callID, code: "unexpected_call")
            case .cancel(let callID): .failed(callID, code: "cancelled")
            }
        }
        let endpoint = try await rpcServer.start()
        let runtime = MillerCapabilityBridgeRuntime(
            rpcClient: CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1)),
            providerProfileID: profileID
        )
        let server = await runtime.makeServer()
        let transports = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: transports.server)
        let client = Client(name: "bridge-test", version: "1.0")
        _ = try await client.connect(transport: transports.client)

        let result = try await client.callTool(name: "not_cataloged").value
        #expect(result.isError == true)

        await client.disconnect()
        await server.stop()
        await rpcServer.stop()
    }

    @Test
    func realAdapterAuthenticatesAndExitsWhenTheBrokerStops() async throws {
        let trustedParent = try bridgeTrustedParent(
            prefix: "miller-bridge-subprocess"
        )
        defer { try? FileManager.default.removeItem(at: trustedParent) }
        let profileID = UUID()
        let probe = BridgeListProbe()
        let rpcServer = CapabilityRPCServer(trustedParent: trustedParent) {
            request in
            if case .list(let receivedProfileID) = request {
                await probe.record(receivedProfileID)
                return .catalog([])
            }
            return .failed(nil, code: "unexpected")
        }
        let endpoint = try await rpcServer.start()
        let child = try launchBridgeSubprocess(
            executable: try bridgeExecutableURL(),
            endpoint: endpoint,
            providerProfileID: profileID
        )
        defer { child.forceCleanup() }

        try await child.sendMCPHandshakeAndList()
        #expect(await waitForList(probe, profileID: profileID))
        #expect(child.process.isRunning)
        #expect(child.process.arguments?.contains(endpoint.token.environmentValue) != true)

        await rpcServer.stop()
        #expect(await waitForExit(child.process))
        #expect(processDoesNotExist(child.process.processIdentifier))
        child.closeInput()
        let output = child.readOutput()
        #expect(!output.contains(Data(endpoint.token.environmentValue.utf8)))
        #expect(!FileManager.default.fileExists(
            atPath: CapabilityRPCRuntime.managedRoot(in: trustedParent).path
        ))
        #expect(try tokenIsAbsent(
            endpoint.token.environmentValue,
            beneath: repositoryRoot().appending(path: ".artifacts")
        ))
    }

    @Test
    func realAdapterRejectsWrongTokenAndExitsOnStdioEOF() async throws {
        let trustedParent = try bridgeTrustedParent(
            prefix: "miller-bridge-auth-subprocess"
        )
        defer { try? FileManager.default.removeItem(at: trustedParent) }
        let profileID = UUID()
        let probe = BridgeListProbe()
        let rpcServer = CapabilityRPCServer(trustedParent: trustedParent) {
            request in
            if case .list(let receivedProfileID) = request {
                await probe.record(receivedProfileID)
            }
            return .catalog([])
        }
        let endpoint = try await rpcServer.start()
        let wrongEndpoint = CapabilityRPCEndpoint(
            socketURL: endpoint.socketURL,
            token: .random(),
            trustedParentURL: endpoint.trustedParentURL
        )
        let child = try launchBridgeSubprocess(
            executable: try bridgeExecutableURL(),
            endpoint: wrongEndpoint,
            providerProfileID: profileID
        )
        defer { child.forceCleanup() }

        try await child.sendMCPHandshakeAndList()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await probe.profileIDs.isEmpty)
        child.closeInput()
        #expect(await waitForExit(child.process))
        #expect(processDoesNotExist(child.process.processIdentifier))
        let output = child.readOutput()
        #expect(!output.contains(Data(wrongEndpoint.token.environmentValue.utf8)))

        await rpcServer.stop()
        #expect(!FileManager.default.fileExists(
            atPath: CapabilityRPCRuntime.managedRoot(in: trustedParent).path
        ))
    }

    @Test
    func cleanupTerminatesOnlyTheBridgeHoldingTheExactManagedLease() async throws {
        let managedParent = try cleanTrustedParent()
        let otherParent = try bridgeTrustedParent(prefix: "miller-bridge-other")
        defer {
            try? FileManager.default.removeItem(at: managedParent)
            try? FileManager.default.removeItem(at: otherParent)
        }
        let managedServer = CapabilityRPCServer(trustedParent: managedParent) {
            _ in .catalog([])
        }
        let otherServer = CapabilityRPCServer(trustedParent: otherParent) {
            _ in .catalog([])
        }
        let managedEndpoint = try await managedServer.start()
        let otherEndpoint = try await otherServer.start()
        let executable = try bridgeExecutableURL()
        let managedBridge = try launchBridgeSubprocess(
            executable: executable,
            endpoint: managedEndpoint,
            providerProfileID: UUID()
        )
        let otherBridge = try launchBridgeSubprocess(
            executable: executable,
            endpoint: otherEndpoint,
            providerProfileID: UUID()
        )
        defer {
            managedBridge.forceCleanup()
            otherBridge.forceCleanup()
        }

        #expect(await waitForLease(in: managedParent))
        #expect(await waitForLease(in: otherParent))
        let clean = try runBridgeRuntimeClean(parent: managedParent)
        #expect(clean.status == 0, Comment(rawValue: clean.error))
        #expect(await waitForExit(managedBridge.process))
        #expect(otherBridge.process.isRunning)
        #expect(FileManager.default.fileExists(atPath: managedParent.path))
        #expect(!FileManager.default.fileExists(
            atPath: CapabilityRPCRuntime.managedRoot(in: managedParent).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: CapabilityRPCRuntime.managedRoot(in: otherParent).path
        ))

        otherBridge.closeInput()
        #expect(await waitForExit(otherBridge.process))
        await managedServer.stop()
        await otherServer.stop()
    }

    @Test
    func cleanupRefusesUnsafeRuntimeMetadata() throws {
        let unsafeModeParent = try cleanTrustedParent()
        defer { try? FileManager.default.removeItem(at: unsafeModeParent) }
        let unsafeRoot = CapabilityRPCRuntime.managedRoot(in: unsafeModeParent)
        try FileManager.default.createDirectory(
            at: unsafeRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let unsafeMode = try runBridgeRuntimeClean(parent: unsafeModeParent)
        #expect(unsafeMode.status != 0)
        #expect(FileManager.default.fileExists(atPath: unsafeRoot.path))

        try FileManager.default.removeItem(at: unsafeRoot)
        try FileManager.default.createDirectory(
            at: unsafeRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unsafeLease = unsafeRoot.appending(
            path: CapabilityRPCRuntime.processLeaseName
        )
        try Data("\(getpid())\n".utf8).write(to: unsafeLease)
        _ = chmod(unsafeLease.path, 0o644)
        let unsafeLeaseResult = try runBridgeRuntimeClean(
            parent: unsafeModeParent
        )
        #expect(unsafeLeaseResult.status != 0)
        #expect(FileManager.default.fileExists(atPath: unsafeLease.path))

        let symlinkParent = try cleanTrustedParent()
        defer { try? FileManager.default.removeItem(at: symlinkParent) }
        let destination = symlinkParent.appending(path: "destination")
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let linkedRoot = CapabilityRPCRuntime.managedRoot(in: symlinkParent)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: destination
        )
        let symlink = try runBridgeRuntimeClean(parent: symlinkParent)
        #expect(symlink.status != 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}

private actor BridgeListProbe {
    private(set) var profileIDs: [UUID] = []
    func record(_ profileID: UUID) { profileIDs.append(profileID) }
}

private final class BridgeSubprocess {
    let process: Process
    private let input: Pipe
    private let output: Pipe
    private let error: Pipe
    private var capturedOutput = Data()
    private var completeOutput = Data()

    init(process: Process, input: Pipe, output: Pipe, error: Pipe) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }

    func sendMCPHandshakeAndList() async throws {
        try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": ["name": "bridge-subprocess-test", "version": "1"],
            ],
        ])
        _ = try await readOutputLine()
        try send([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ])
        try send([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [:],
        ])
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    func readOutput() -> Data {
        guard !process.isRunning else { return capturedOutput }
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        var data = completeOutput
        data.append(output.fileHandleForReading.readDataToEndOfFile())
        data.append(error.fileHandleForReading.readDataToEndOfFile())
        return data
    }

    func forceCleanup() {
        closeInput()
        if process.isRunning {
            process.terminate()
            for _ in 0..<40 where process.isRunning { usleep(25_000) }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        data.append(UInt8(ascii: "\n"))
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readOutputLine() async throws -> Data {
        let descriptor = output.fileHandleForReading.fileDescriptor
        for _ in 0..<80 {
            if let newline = capturedOutput.firstIndex(of: UInt8(ascii: "\n")) {
                let line = capturedOutput[..<newline]
                capturedOutput.removeSubrange(...newline)
                return Data(line)
            }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                capturedOutput.append(contentsOf: buffer[..<count])
                completeOutput.append(contentsOf: buffer[..<count])
                continue
            }
            if count == 0 { throw MillerCapabilityBridgeError.brokerUnavailable }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw MillerCapabilityBridgeError.brokerUnavailable
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MillerCapabilityBridgeError.brokerUnavailable
    }
}

private func launchBridgeSubprocess(
    executable: URL,
    endpoint: CapabilityRPCEndpoint,
    providerProfileID: UUID
) throws -> BridgeSubprocess {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = []
    process.environment = [
        "HOME": "/nonexistent",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": endpoint.socketURL.deletingLastPathComponent().path,
        CapabilityRPCEnvironment.socketPath: endpoint.socketURL.path,
        CapabilityRPCEnvironment.sessionToken: endpoint.token.environmentValue,
        CapabilityRPCEnvironment.providerProfileID: providerProfileID.uuidString,
        CapabilityRPCEnvironment.trustedParent: endpoint.trustedParentURL.path,
    ]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    return BridgeSubprocess(
        process: process,
        input: input,
        output: output,
        error: error
    )
}

private func processDoesNotExist(_ processID: Int32) -> Bool {
    errno = 0
    return kill(processID, 0) == -1 && errno == ESRCH
}

private func bridgeExecutableURL() throws -> URL {
    let resourceSibling = Bundle.module.bundleURL
        .deletingLastPathComponent()
        .appending(path: "MillerCapabilityBridge")
    if FileManager.default.isExecutableFile(atPath: resourceSibling.path) {
        return resourceSibling
    }
    var directory = URL(filePath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = directory.appending(path: "MillerCapabilityBridge")
        if FileManager.default.isExecutableFile(atPath: candidate.path),
           !candidate.hasDirectoryPath
        {
            return candidate
        }
        directory.deleteLastPathComponent()
    }
    throw MillerCapabilityBridgeError.invalidEnvironment
}

private func waitForList(
    _ probe: BridgeListProbe,
    profileID: UUID
) async -> Bool {
    for _ in 0..<80 {
        if await probe.profileIDs.contains(profileID) { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

private func waitForExit(_ process: Process) async -> Bool {
    for _ in 0..<80 {
        if !process.isRunning { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return !process.isRunning
}

private func waitForLease(in trustedParent: URL) async -> Bool {
    let lease = CapabilityRPCRuntime.managedRoot(in: trustedParent)
        .appending(path: CapabilityRPCRuntime.processLeaseName)
    for _ in 0..<80 {
        if FileManager.default.fileExists(atPath: lease.path) { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return false
}

private func runBridgeRuntimeClean(parent: URL) throws -> (
    status: Int32,
    error: String
) {
    let process = Process()
    let error = Pipe()
    process.executableURL = repositoryRoot().appending(path: "scripts/clean.sh")
    process.arguments = ["--bridge-runtime"]
    process.environment = [
        "HOME": "/nonexistent",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "MILLER_CLEAN_TESTING": "1",
        "MILLER_CLEAN_BRIDGE_PARENT": parent.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func tokenIsAbsent(_ token: String, beneath root: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: root.path) else { return true }
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys
    ) else { return false }
    let needle = Data(token.utf8)
    for case let file as URL in enumerator {
        guard try file.resourceValues(forKeys: Set(keys)).isRegularFile == true else {
            continue
        }
        if try Data(contentsOf: file, options: [.mappedIfSafe]).range(of: needle) != nil {
            return false
        }
    }
    return true
}

private func repositoryRoot() -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func bridgeTrustedParent(prefix: String) throws -> URL {
    let url = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        .appending(path: "\(prefix.prefix(12))-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func cleanTrustedParent() throws -> URL {
    let url = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
        .appending(
            path: "miller-clean-test-\(geteuid())-\(UUID().uuidString.prefix(8))"
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private actor BridgeCallProbe {
    private(set) var callID: CapabilityCallID?
    private(set) var capabilityID: CapabilityID?
    private(set) var argumentsJSON: Data?

    func record(
        callID: CapabilityCallID,
        capabilityID: CapabilityID,
        argumentsJSON: Data
    ) {
        self.callID = callID
        self.capabilityID = capabilityID
        self.argumentsJSON = argumentsJSON
    }
}

private func makeBridgeDescriptor(profileID: UUID) throws -> CapabilityDescriptor {
    let id = try CapabilityID(
        source: .millerMCP, serverID: "local", toolName: "lookup"
    )
    return try CapabilityDescriptor(
        id: id,
        source: .millerMCP,
        serverID: "local",
        toolName: "lookup",
        displayName: "Lookup",
        summary: "Looks up a value",
        inputSchemaJSON: Data(
            #"{"type":"object","properties":{"query":{"type":"string"}}}"#.utf8
        ),
        readOnlyHint: true,
        providerProfileIDs: [profileID],
        isAvailable: true
    )
}
