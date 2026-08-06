import Darwin
import Foundation
@testable import MillerCapabilities
import MillerCore
import Testing

@Suite(.serialized)
struct CapabilityRPCTests {
    @Test
    func createsPrivateRuntimeAndSocketWithEphemeralToken() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = CapabilityRPCRuntime.managedRoot(in: parent)
        let server = CapabilityRPCServer(
            trustedParent: parent,
            handler: { _ in .failed(nil, code: "unused") }
        )

        let endpoint = try await server.start()
        #expect(endpoint.token.bytes.count == 32)
        #expect(mode(root) == 0o700)
        #expect(mode(endpoint.socketURL) == 0o600)
        #expect(FileManager.default.fileExists(atPath: endpoint.socketURL.path))

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: endpoint.socketURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func rejectsShortTokensOversizeFramesAndMalformedJSON() throws {
        #expect(throws: CapabilityRPCError.invalidToken) {
            _ = try CapabilityRPCSessionToken(bytes: Data(repeating: 1, count: 31))
        }

        let request = CapabilityRPCRequest.list(providerProfileID: UUID())
        let envelope = CapabilityRPCRequestEnvelope(
            requestID: UUID(), request: request
        )
        #expect(throws: CapabilityRPCError.frameTooLarge) {
            _ = try CapabilityRPCCodec.encode(envelope, maximumFrameBytes: 8)
        }
        #expect(throws: CapabilityRPCError.malformedFrame) {
            _ = try CapabilityRPCCodec.decode(
                CapabilityRPCRequestEnvelope.self,
                from: Data("not-json".utf8)
            )
        }
    }

    @Test
    func authenticatesBeforeAcceptingARequestAndCorrelatesOneID() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let profileID = UUID()
        let descriptor = try makeDescriptor(profileID: profileID)
        let server = CapabilityRPCServer(trustedParent: parent) { request in
            guard case .list(let received) = request, received == profileID else {
                return .failed(nil, code: "unexpected")
            }
            return .catalog([descriptor])
        }
        let endpoint = try await server.start()

        let unauthenticated = try connectUnixSocket(endpoint.socketURL)
        defer { Darwin.close(unauthenticated) }
        let raw = try CapabilityRPCCodec.encode(
            CapabilityRPCRequestEnvelope(
                requestID: UUID(), request: .list(providerProfileID: profileID)
            )
        )
        try writeFrame(raw, to: unauthenticated)
        let rejection = try readFrame(from: unauthenticated)
        let authFailure = try CapabilityRPCCodec.decode(
            CapabilityRPCResponseEnvelope.self, from: rejection
        )
        #expect(authFailure.response == .failed(nil, code: "authentication_failed"))

        let client = CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1))
        let response = try await client.send(.list(providerProfileID: profileID))
        #expect(response == .catalog([descriptor]))
        await server.stop()
    }

    @Test
    func timesOutAndRejectsPeerDisconnect() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let server = CapabilityRPCServer(trustedParent: parent) { _ in
            try? await Task.sleep(for: .seconds(1))
            return .failed(nil, code: "late")
        }
        let endpoint = try await server.start()
        let client = CapabilityRPCClient(
            endpoint: endpoint, timeout: .milliseconds(40)
        )
        await #expect(throws: CapabilityRPCError.timedOut) {
            _ = try await client.send(.list(providerProfileID: UUID()))
        }

        let pending = Task {
            try await CapabilityRPCClient(
                endpoint: endpoint, timeout: .seconds(1)
            ).send(.list(providerProfileID: UUID()))
        }
        try await Task.sleep(for: .milliseconds(20))
        await server.stop()
        await #expect(throws: CapabilityRPCError.peerDisconnected) {
            _ = try await pending.value
        }
    }

    @Test
    func cancellingCallForwardsCancelAndCleansAdapterEnvironment() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = CapabilityRPCRuntime.managedRoot(in: parent)
        let callID = CapabilityCallID()
        let cancellation = CancellationProbe()
        let server = CapabilityRPCServer(trustedParent: parent) { request in
            switch request {
            case .call:
                try? await Task.sleep(for: .seconds(2))
                return .failed(callID, code: "late")
            case .cancel(let received):
                await cancellation.record(received)
                return .failed(received, code: "cancelled")
            case .list:
                return .catalog([])
            }
        }
        let endpoint = try await server.start()
        let environment = endpoint.adapterEnvironment
        #expect(environment[CapabilityRPCEnvironment.socketPath] == endpoint.socketURL.path)
        #expect(environment[CapabilityRPCEnvironment.sessionToken] != nil)

        let client = CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1))
        let task = Task {
            try await client.call(
                callID: callID,
                capabilityID: try CapabilityID(
                    source: .millerMCP, serverID: "local", toolName: "slow"
                ),
                argumentsJSON: Data("{}".utf8)
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await cancellation.callID == callID)

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func anchorsRuntimeAuthorityToTheExactManagedChild() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = CapabilityRPCRuntime.managedRoot(in: parent)
        try CapabilityRPCRuntime.prepareManagedRoot(
            root,
            trustedParent: parent
        )
        try CapabilityRPCRuntime.removeManagedRoot(
            root,
            trustedParent: parent
        )
        #expect(FileManager.default.fileExists(atPath: parent.path))

        let sibling = parent.appending(path: "arbitrary")
        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            try CapabilityRPCRuntime.removeManagedRoot(
                sibling,
                trustedParent: parent
            )
        }

        let outside = parent.deletingLastPathComponent().appending(
            path: "outside-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            try CapabilityRPCRuntime.removeManagedRoot(
                outside,
                trustedParent: parent
            )
        }

        let nested = root.appending(path: CapabilityRPCRuntime.managedChildName)
        #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            try CapabilityRPCRuntime.prepareManagedRoot(
                nested,
                trustedParent: parent
            )
        }
    }

    @Test
    func refusesSymlinksAndUnsafeRuntimePermissions() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = CapabilityRPCRuntime.managedRoot(in: parent)
        let outside = parent.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let link = root
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside
        )
        let linked = CapabilityRPCServer(trustedParent: parent) { _ in .catalog([]) }
        await #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            _ = try await linked.start()
        }

        try FileManager.default.removeItem(at: link)
        let realAncestor = parent.appending(path: "real")
        let realParent = realAncestor.appending(path: "parent")
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(realAncestor.path, 0o700)
        let alias = parent.appending(path: "alias")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: realAncestor
        )
        let aliasedParent = alias.appending(path: "parent")
        let aliased = CapabilityRPCServer(trustedParent: aliasedParent) {
            _ in .catalog([])
        }
        await #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            _ = try await aliased.start()
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            try CapabilityRPCRuntime.prepareManagedRoot(
                root,
                trustedParent: parent
            )
        }

        try FileManager.default.removeItem(at: root)
        _ = chmod(parent.path, 0o755)
        let unsafeParent = CapabilityRPCServer(trustedParent: parent) {
            _ in .catalog([])
        }
        await #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            _ = try await unsafeParent.start()
        }

        let nonOwnedParent = CapabilityRPCServer(
            trustedParent: URL(
                filePath: "/private/tmp",
                directoryHint: .isDirectory
            )
        ) { _ in .catalog([]) }
        await #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            _ = try await nonOwnedParent.start()
        }
    }

    @Test
    func peerDisconnectCancelsInFlightCallWithoutLateSideEffects() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let probe = HandlerCancellationProbe()
        let callID = CapabilityCallID()
        let server = CapabilityRPCServer(trustedParent: parent) { request in
            guard case .call = request else { return .catalog([]) }
            return await withTaskCancellationHandler {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return .failed(callID, code: "cancelled") }
                probe.recordSideEffect()
                return .result(
                    callID,
                    contentJSON: Data(#"{"content":[]}"#.utf8),
                    isError: false
                )
            } onCancel: {
                probe.recordCancellation()
            }
        }
        let endpoint = try await server.start()
        let descriptor = try connectUnixSocket(endpoint.socketURL)
        try writeRPCFrame(
            CapabilityRPCAuthenticationFrame(token: endpoint.token),
            to: descriptor
        )
        try writeRPCFrame(
            CapabilityRPCRequestEnvelope(
                requestID: UUID(),
                request: .call(
                    callID,
                    capabilityID: try CapabilityID(
                        source: .millerMCP,
                        serverID: "local",
                        toolName: "change"
                    ),
                    argumentsJSON: Data("{}".utf8)
                )
            ),
            to: descriptor
        )
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)

        #expect(await probe.waitForCancellation())
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.sideEffectCount == 0)

        let healthy = CapabilityRPCClient(endpoint: endpoint, timeout: .seconds(1))
        #expect(try await healthy.send(.list(providerProfileID: UUID())) == .catalog([]))
        await server.stop()
        #expect(await server.activeClientCountForTesting() == 0)
    }

    @Test
    func stopRestartInvalidatesOldAcceptGenerationAndToken() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let server = CapabilityRPCServer(
            trustedParent: parent,
            authenticationTimeout: .milliseconds(100),
            requestFrameTimeout: .milliseconds(100)
        ) { _ in .catalog([]) }

        var oldToken: CapabilityRPCSessionToken?
        for _ in 0..<12 {
            let endpoint = try await server.start()
            let staleClient = try connectUnixSocket(endpoint.socketURL)
            oldToken = endpoint.token
            await server.stop()
            Darwin.close(staleClient)
            #expect(await server.activeClientCountForTesting() == 0)
            #expect(!FileManager.default.fileExists(
                atPath: CapabilityRPCRuntime.managedRoot(in: parent).path
            ))
        }

        let current = try await server.start()
        let stale = CapabilityRPCClient(
            socketURL: current.socketURL,
            token: try #require(oldToken),
            timeout: .seconds(1)
        )
        await #expect(throws: CapabilityRPCError.authenticationFailed) {
            _ = try await stale.send(.list(providerProfileID: UUID()))
        }
        #expect(try await CapabilityRPCClient(
            endpoint: current,
            timeout: .seconds(1)
        ).send(.list(providerProfileID: UUID())) == .catalog([]))
        await server.stop()
        #expect(await server.activeClientCountForTesting() == 0)
    }

    @Test
    func boundsClientsAndUsesAbsoluteInputDeadlines() async throws {
        let parent = try trustedRuntimeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let server = CapabilityRPCServer(
            trustedParent: parent,
            authenticationTimeout: .milliseconds(120),
            requestFrameTimeout: .milliseconds(120)
        ) { _ in
            try? await Task.sleep(for: .milliseconds(250))
            return .catalog([])
        }
        let endpoint = try await server.start()

        var stalled: [Int32] = []
        for _ in 0..<CapabilityRPCServer.maximumActiveClients {
            stalled.append(try connectUnixSocket(endpoint.socketURL))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(
            await server.activeClientCountForTesting()
                == CapabilityRPCServer.maximumActiveClients
        )
        let excess = try connectUnixSocket(endpoint.socketURL)
        await #expect(throws: (any Error).self) {
            _ = try await Task.detached { try readFrame(from: excess) }.value
        }
        Darwin.close(excess)
        for descriptor in stalled { Darwin.close(descriptor) }

        let trickle = try connectUnixSocket(endpoint.socketURL)
        for byte in Data(#"{"token":"# .utf8) {
            _ = Darwin.write(trickle, [byte], 1)
            try await Task.sleep(for: .milliseconds(35))
        }
        await #expect(throws: (any Error).self) {
            _ = try await Task.detached { try readFrame(from: trickle) }.value
        }
        Darwin.close(trickle)

        let longHandlerClient = CapabilityRPCClient(
            endpoint: endpoint,
            timeout: .seconds(1)
        )
        #expect(try await longHandlerClient.send(
            .list(providerProfileID: UUID())
        ) == .catalog([]))
        await server.stop()
        #expect(await server.activeClientCountForTesting() == 0)
    }
}

private actor CancellationProbe {
    private(set) var callID: CapabilityCallID?
    func record(_ callID: CapabilityCallID) { self.callID = callID }
}

private final class HandlerCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0
    private var sideEffects = 0

    var sideEffectCount: Int {
        lock.withLock { sideEffects }
    }

    func recordCancellation() {
        lock.withLock { cancellations += 1 }
    }

    func recordSideEffect() {
        lock.withLock { sideEffects += 1 }
    }

    func waitForCancellation() async -> Bool {
        for _ in 0..<80 {
            if lock.withLock({ cancellations > 0 }) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

private func makeDescriptor(profileID: UUID) throws -> CapabilityDescriptor {
    let id = try CapabilityID(
        source: .millerMCP, serverID: "local", toolName: "lookup"
    )
    return try CapabilityDescriptor(
        id: id, source: .millerMCP, serverID: "local", toolName: "lookup",
        displayName: "Lookup", summary: "Looks up a value",
        inputSchemaJSON: Data(#"{"type":"object"}"#.utf8),
        readOnlyHint: true, providerProfileIDs: [profileID], isAvailable: true
    )
}

private func trustedRuntimeParent() throws -> URL {
    let url = URL(filePath: "/private/tmp", directoryHint: .isDirectory).appending(
        path: "miller-rpc-test-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func mode(_ url: URL) -> mode_t {
    var value = stat()
    _ = lstat(url.path, &value)
    return value.st_mode & 0o777
}

private func connectUnixSocket(_ url: URL) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    var noSignal: Int32 = 1
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    )
    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    _ = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(url.path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(descriptor)
        throw POSIXError(.ENAMETOOLONG)
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
                descriptor, $0,
                socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            )
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }
    return descriptor
}

private func writeFrame(_ data: Data, to descriptor: Int32) throws {
    var framed = data
    framed.append(UInt8(ascii: "\n"))
    try framed.withUnsafeBytes { bytes in
        guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
            throw POSIXError(.EIO)
        }
    }
}

private func readFrame(from descriptor: Int32) throws -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while Darwin.read(descriptor, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { return result }
        result.append(byte)
    }
    throw POSIXError(.ECONNRESET)
}
