import Darwin
import Foundation
@testable import MillerCapabilities
import MillerCore
import Testing

@Suite(.serialized)
struct CapabilityRPCTests {
    @Test
    func createsPrivateRuntimeAndSocketWithEphemeralToken() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "rpc")
        let server = CapabilityRPCServer(
            runtimeRoot: root,
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
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "rpc")
        let profileID = UUID()
        let descriptor = try makeDescriptor(profileID: profileID)
        let server = CapabilityRPCServer(runtimeRoot: root) { request in
            guard case .list(let received) = request, received == profileID else {
                return .failed(nil, code: "unexpected")
            }
            return .catalog([descriptor])
        }
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }

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
    }

    @Test
    func timesOutAndRejectsPeerDisconnect() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "rpc")
        let server = CapabilityRPCServer(runtimeRoot: root) { _ in
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
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "rpc")
        let callID = CapabilityCallID()
        let cancellation = CancellationProbe()
        let server = CapabilityRPCServer(runtimeRoot: root) { request in
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
    func refusesSymlinkRuntimeRootAndUnsafeCleanupTargets() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appending(path: "outside")
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false
        )
        let link = parent.appending(path: "link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside
        )
        let linked = CapabilityRPCServer(runtimeRoot: link) { _ in .catalog([]) }
        await #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            _ = try await linked.start()
        }

        #expect(throws: CapabilityRPCError.unsafeRuntimeRoot) {
            try CapabilityRPCRuntime.removeManagedRoot(
                outside, allowedParent: parent.appending(path: "different")
            )
        }
    }
}

private actor CancellationProbe {
    private(set) var callID: CapabilityCallID?
    func record(_ callID: CapabilityCallID) { self.callID = callID }
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

private func temporaryDirectory() throws -> URL {
    let url = URL(filePath: "/tmp", directoryHint: .isDirectory).appending(
        path: "miller-rpc-test-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: false
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
