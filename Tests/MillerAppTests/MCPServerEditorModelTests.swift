import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct MCPServerEditorModelTests {
    @Test
    func validatesStdioArgumentsAsLiteralArgumentArrays() throws {
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "notes"
        draft.displayName = "Notes"
        draft.executable = "/usr/bin/env"
        draft.argumentsJSON = #"["node","server.mjs","--safe"]"#

        let validated = try draft.validated(mode: .create)
        #expect(validated.server.command == "/usr/bin/env")
        #expect(validated.server.arguments == ["node", "server.mjs", "--safe"])

        draft.executable = "node"
        #expect(throws: MCPServerEditorError.executableMustBeAbsolute) {
            _ = try draft.validated(mode: .create)
        }
        draft.executable = "/usr/bin/env"
        draft.argumentsJSON = "node server.mjs --safe"
        #expect(throws: MCPServerEditorError.argumentsMustBeJSONArray) {
            _ = try draft.validated(mode: .create)
        }
        draft.argumentsJSON = #"["a && b","$(literal)","x|y","a>b"]"#
        #expect(try draft.validated(mode: .create).server.arguments == [
            "a && b", "$(literal)", "x|y", "a>b",
        ])
    }

    @Test
    func normalizesHTTPSAndRejectsNonHTTPSRemoteEndpoints() throws {
        var draft = MCPServerEditorDraft.newHTTPS
        draft.id = "remote"
        draft.displayName = "Remote"
        draft.endpoint = " HTTPS://EXAMPLE.COM:443/mcp/ "

        #expect(try draft.validated(mode: .create).server.endpoint
            == "https://example.com/mcp")

        draft.endpoint = "http://example.com/mcp"
        #expect(throws: MCPServerEditorError.invalidHTTPSEndpoint) {
            _ = try draft.validated(mode: .create)
        }
        draft.endpoint = "https://user@example.com/mcp"
        #expect(throws: MCPServerEditorError.invalidHTTPSEndpoint) {
            _ = try draft.validated(mode: .create)
        }
    }

    @Test
    func existingSecretMayBePreservedWithoutReenteringItsValue() throws {
        let reference = UUID()
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "weather"
        draft.displayName = "Weather"
        draft.executable = "/usr/bin/weather-mcp"
        draft.secrets = [
            .init(
                kind: .header,
                name: "Authorization",
                value: "",
                existingReference: reference
            ),
        ]

        let validated = try draft.validated(mode: .create)

        #expect(validated.secrets.first?.credentialReference == reference)
        #expect(validated.secretValues.isEmpty)
    }

    @Test
    func newSecretRequiresAValue() {
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "weather"
        draft.displayName = "Weather"
        draft.executable = "/usr/bin/weather-mcp"
        draft.secrets = [
            .init(kind: .header, name: "Authorization", value: ""),
        ]

        #expect(throws: MCPServerEditorError.invalidSecret) {
            _ = try draft.validated(mode: .create)
        }
    }

    @Test
    func secretNamesMustSatisfyRuntimeBindingRules() {
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "weather"
        draft.displayName = "Weather"
        draft.executable = "/usr/bin/weather-mcp"
        draft.secrets = [
            .init(kind: .environment, name: "1TOKEN", value: "private"),
        ]
        #expect(throws: MCPServerEditorError.invalidSecret) {
            _ = try draft.validated(mode: .create)
        }
        draft.secrets = [
            .init(kind: .header, name: "Bad Header", value: "private"),
        ]
        #expect(throws: MCPServerEditorError.invalidSecret) {
            _ = try draft.validated(mode: .create)
        }
    }

    @Test @MainActor
    func createsEditsAndRemovesServersAndBindsSecretsByGeneratedReference() async throws {
        let recorder = MCPSettingsRecorder()
        let model = MCPServerEditorModel(dependencies: recorder.dependencies)
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "notes"
        draft.displayName = "Notes"
        draft.executable = "/usr/bin/env"
        draft.argumentsJSON = #"["node","notes.mjs"]"#
        draft.secrets = [.init(kind: .environment, name: "NOTES_TOKEN", value: "private")]

        await model.save(draft, mode: .create)
        let saved = try #require(await recorder.saved.last)
        #expect(saved.server.id == "notes")
        #expect(saved.secrets.count == 1)
        #expect(saved.secrets[0].name == "NOTES_TOKEN")
        #expect(saved.secretValues[saved.secrets[0].credentialReference] == "private")
        #expect(!model.status.contains("private"))

        draft.displayName = "Edited Notes"
        draft.secrets = []
        await model.save(draft, mode: .edit(originalID: "notes"))
        #expect(await recorder.saved.last?.server.displayName == "Edited Notes")
        #expect(await recorder.saved.last?.mutationMode == .edit(originalID: "notes"))

        var remote = MCPServerEditorDraft.newHTTPS
        remote.id = "remote-notes"
        remote.displayName = "Remote Notes"
        remote.endpoint = "https://example.com/mcp"
        await model.save(remote, mode: .create)
        #expect(await recorder.saved.last?.server.transport == .streamableHTTP)
        #expect(await recorder.saved.last?.server.endpoint == "https://example.com/mcp")

        await model.remove(serverID: "notes")
        await model.remove(serverID: "remote-notes")
        #expect(await recorder.removed == ["notes", "remote-notes"])
    }

    @Test @MainActor
    func connectionTestPublishesOnlyBoundedStatus() async {
        let recorder = MCPSettingsRecorder()
        let model = MCPServerEditorModel(dependencies: recorder.dependencies)
        await model.testConnection(serverID: "notes")
        #expect(model.connectionStatus["notes"] == "Connected — 2 tools")
        #expect(await recorder.connectionTests == ["notes"])

        await recorder.failNextRefresh()
        await model.refreshCatalogs()
        #expect(model.connectionStatus.isEmpty)
        #expect(model.status == "Catalog refresh failed; last catalog retained as stale")
    }

    @Test @MainActor
    func stalePostTestSnapshotDoesNotPublishConnectedStatus() async {
        let staleSnapshot = CapabilitySettingsSnapshot(servers: [
            .init(
                server: CapabilityServerRecord(
                    id: "notes", displayName: "Notes", transport: .stdio,
                    command: "/usr/bin/true", endpoint: nil, arguments: [],
                    enabled: true, defaultPolicy: .askBeforeChanges,
                    staleState: .stale, createdAt: .distantPast,
                    updatedAt: .distantPast
                ),
                providerNames: [:],
                tools: []
            ),
        ])
        let model = MCPServerEditorModel(dependencies: .init(
            load: { staleSnapshot },
            save: { _ in },
            remove: { _ in },
            testConnection: { _ in 2 },
            setProviderEnabled: { _, _, _ in },
            setServerPolicy: { _, _ in },
            setToolPolicy: { _, _ in },
            refresh: { staleSnapshot }
        ))

        await model.testConnection(serverID: "notes")

        #expect(model.connectionStatus["notes"] == nil)
    }

    @Test @MainActor
    func editingServerClearsPriorConnectedStatus() async {
        let recorder = MCPSettingsRecorder()
        let model = MCPServerEditorModel(dependencies: recorder.dependencies)
        await model.testConnection(serverID: "notes")
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "notes"
        draft.displayName = "Notes"
        draft.executable = "/usr/bin/true"

        await model.save(draft, mode: .edit(originalID: "notes"))

        #expect(model.connectionStatus["notes"] == nil)
    }

    @Test @MainActor
    func privacyResetClearsSnapshotAndRejectsSuspendedPreResetLoad() async {
        let probe = SuspendedMCPSettingsLoadProbe()
        let model = MCPServerEditorModel(dependencies: probe.dependencies)
        await model.load()
        #expect(!model.snapshot.servers.isEmpty)

        let staleLoad = Task { await model.load() }
        await probe.waitUntilSuspendedLoad()
        #expect(model.isBusy)

        model.clearAfterPrivacyReset()

        #expect(model.snapshot == .empty)
        #expect(model.status.isEmpty)
        #expect(model.connectionStatus.isEmpty)
        #expect(!model.isBusy)
        #expect(model.resetEpoch == 1)

        await probe.resumeSuspendedLoad()
        await staleLoad.value
        #expect(model.snapshot == .empty)
        #expect(model.status.isEmpty)
        #expect(!model.isBusy)
    }
}

private enum MCPSettingsRecorderError: Error { case injected }

private actor MCPSettingsRecorder {
    var saved: [MCPServerValidatedDraft] = []
    var removed: [String] = []
    var connectionTests: [String] = []
    var shouldFailRefresh = false

    nonisolated var dependencies: MCPServerEditorDependencies {
        MCPServerEditorDependencies(
            load: { connectedMCPSettingsSnapshot() },
            save: { [self] value in await appendSaved(value) },
            remove: { [self] id in await appendRemoved(id) },
            testConnection: { [self] id in
                await appendConnection(id)
                return 2
            },
            setProviderEnabled: { _, _, _ in },
            setServerPolicy: { _, _ in },
            setToolPolicy: { _, _ in },
            refresh: { [self] in try await refreshSnapshot() }
        )
    }

    private func appendSaved(_ value: MCPServerValidatedDraft) { saved.append(value) }
    private func appendRemoved(_ value: String) { removed.append(value) }
    private func appendConnection(_ value: String) { connectionTests.append(value) }
    func failNextRefresh() { shouldFailRefresh = true }
    private func refreshSnapshot() throws -> CapabilitySettingsSnapshot {
        if shouldFailRefresh {
            shouldFailRefresh = false
            throw MCPSettingsRecorderError.injected
        }
        return .empty
    }
}

private actor SuspendedMCPSettingsLoadProbe {
    private var loadCount = 0
    private var continuation: CheckedContinuation<CapabilitySettingsSnapshot, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var suspended = false

    nonisolated var dependencies: MCPServerEditorDependencies {
        .init(
            load: { [self] in await load() },
            save: { _ in }, remove: { _ in }, testConnection: { _ in 0 },
            setProviderEnabled: { _, _, _ in }, setServerPolicy: { _, _ in },
            setToolPolicy: { _, _ in }, refresh: { .empty }
        )
    }

    private func load() async -> CapabilitySettingsSnapshot {
        loadCount += 1
        guard loadCount > 1 else { return connectedMCPSettingsSnapshot() }
        suspended = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspendedLoad() async {
        if suspended { return }
        await withCheckedContinuation { continuation in
            if suspended {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func resumeSuspendedLoad() {
        continuation?.resume(returning: connectedMCPSettingsSnapshot())
        continuation = nil
    }
}

private func connectedMCPSettingsSnapshot() -> CapabilitySettingsSnapshot {
    .init(servers: [
        .init(
            server: CapabilityServerRecord(
                id: "notes", displayName: "Notes", transport: .stdio,
                command: "/usr/bin/true", endpoint: nil, arguments: [],
                enabled: true, defaultPolicy: .askBeforeChanges,
                staleState: .current, createdAt: .distantPast,
                updatedAt: .distantPast
            ),
            providerNames: [:],
            tools: []
        ),
    ])
}
