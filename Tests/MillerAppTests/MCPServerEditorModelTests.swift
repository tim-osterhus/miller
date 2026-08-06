import Foundation
import MillerCore
import MillerStorage
import Testing
@testable import MillerApp

@Suite
struct MCPServerEditorModelTests {
    @Test
    func validatesStdioArgumentsWithoutAcceptingShellCommandStrings() throws {
        var draft = MCPServerEditorDraft.newStdio
        draft.id = "notes"
        draft.displayName = "Notes"
        draft.executable = "/usr/bin/env"
        draft.argumentsJSON = #"["node","server.mjs","--safe"]"#

        let validated = try draft.validated()
        #expect(validated.server.command == "/usr/bin/env")
        #expect(validated.server.arguments == ["node", "server.mjs", "--safe"])

        draft.executable = "node"
        #expect(throws: MCPServerEditorError.executableMustBeAbsolute) {
            _ = try draft.validated()
        }
        draft.executable = "/usr/bin/env"
        draft.argumentsJSON = "node server.mjs --safe"
        #expect(throws: MCPServerEditorError.argumentsMustBeJSONArray) {
            _ = try draft.validated()
        }
        draft.argumentsJSON = #"["node && rm -rf /tmp/x"]"#
        #expect(throws: MCPServerEditorError.shellSyntaxNotAllowed) {
            _ = try draft.validated()
        }
    }

    @Test
    func normalizesHTTPSAndRejectsNonHTTPSRemoteEndpoints() throws {
        var draft = MCPServerEditorDraft.newHTTPS
        draft.id = "remote"
        draft.displayName = "Remote"
        draft.endpoint = " HTTPS://EXAMPLE.COM:443/mcp/ "

        #expect(try draft.validated().server.endpoint == "https://example.com/mcp")

        draft.endpoint = "http://example.com/mcp"
        #expect(throws: MCPServerEditorError.invalidHTTPSEndpoint) {
            _ = try draft.validated()
        }
        draft.endpoint = "https://user@example.com/mcp"
        #expect(throws: MCPServerEditorError.invalidHTTPSEndpoint) {
            _ = try draft.validated()
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

        let validated = try draft.validated()

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
            _ = try draft.validated()
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

        await model.save(draft)
        let saved = try #require(await recorder.saved.last)
        #expect(saved.server.id == "notes")
        #expect(saved.secrets.count == 1)
        #expect(saved.secrets[0].name == "NOTES_TOKEN")
        #expect(saved.secretValues[saved.secrets[0].credentialReference] == "private")
        #expect(!model.status.contains("private"))

        draft.displayName = "Edited Notes"
        draft.secrets = []
        await model.save(draft)
        #expect(await recorder.saved.last?.server.displayName == "Edited Notes")

        var remote = MCPServerEditorDraft.newHTTPS
        remote.id = "remote-notes"
        remote.displayName = "Remote Notes"
        remote.endpoint = "https://example.com/mcp"
        await model.save(remote)
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
    }
}

private actor MCPSettingsRecorder {
    var saved: [MCPServerValidatedDraft] = []
    var removed: [String] = []
    var connectionTests: [String] = []

    nonisolated var dependencies: MCPServerEditorDependencies {
        MCPServerEditorDependencies(
            load: { .empty },
            save: { [self] value in await appendSaved(value) },
            remove: { [self] id in await appendRemoved(id) },
            testConnection: { [self] id in
                await appendConnection(id)
                return 2
            },
            setProviderEnabled: { _, _, _ in },
            setServerPolicy: { _, _ in },
            setToolPolicy: { _, _ in },
            refresh: { .empty }
        )
    }

    private func appendSaved(_ value: MCPServerValidatedDraft) { saved.append(value) }
    private func appendRemoved(_ value: String) { removed.append(value) }
    private func appendConnection(_ value: String) { connectionTests.append(value) }
}
