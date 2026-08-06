import Darwin
import Foundation
import MillerCore
import MillerGateway
import MillerLive
import MillerLiveAudio
import MillerStorage
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct PortableSkillRoutingTests {
    @Test
    func boundedSkillOmissionIsVisibleWithoutTranscriptContamination() async {
        let turnID = TurnID()
        let model = AppPresentationModel(dependencies: HostDependencies(
            submit: { _, _ in turnID }, stop: {},
            loadTurn: { _ in nil }, loadConversations: { [] }, loadTurns: { _ in [] },
            archive: { _ in }, unarchive: { _ in }, delete: { _ in },
            reasoningStatus: { .portableSkillsOmitted }
        ))
        model.draft = "use skills"

        await model.submit()
        for _ in 0..<50 where !model.statusText.contains("skills were omitted") {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.statusText == "Some enabled skills were omitted to stay within limits")
        #expect(model.visibleTurns.isEmpty)
    }

    @Test
    func productionAdaptersProjectOneImportedSkillProspectivelyAndPreserveDurableTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "miller-portable-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appending(path: "db.sqlite3").path
        let repository = try SQLiteCapabilityRepository(path: databasePath)
        let codex = try ProviderProfile(
            kind: .codexOAuth, label: "Codex", baseURL: nil,
            model: "gpt-5.6-terra", isSelected: true
        )
        let deepSeek = try ProviderProfile(
            kind: .openAICompatible, label: "DeepSeek",
            baseURL: "https://api.deepseek.com", model: "deepseek-chat"
        )
        let profileRepository = try SQLiteConversationRepository(path: databasePath)
        try await profileRepository.saveProviderProfile(codex)
        try await profileRepository.saveProviderProfile(deepSeek)
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )
        await controller.start()
        let source = root.appending(path: "weather")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(
            """
            ---
            name: Weather
            description: Forecast guidance
            ---
            Use forecasts.

            """.utf8
        ).write(to: source.appending(path: "SKILL.md"))
        try await controller.importPortableSkillFromSettings(at: source)
        let skill = try #require(try await repository.skills().first)
        try await controller.setPortableSkillEnabledFromSettings(
            true, skillID: skill.id, providerProfileID: codex.id
        )
        try await controller.setPortableSkillEnabledFromSettings(
            true, skillID: skill.id, providerProfileID: deepSeek.id
        )

        let durableConversationID = ConversationID()
        let durableTurnID = TurnID()
        try await profileRepository.accept(
            conversationID: durableConversationID, turnID: durableTurnID,
            userText: "durable question", inputMode: .text, generation: 1
        )
        try await profileRepository.append(
            turnID: durableTurnID, text: "durable answer", generation: 1
        )
        try await profileRepository.complete(turnID: durableTurnID, generation: 1)
        let durableTurnBeforeMutation = try #require(
            try await profileRepository.turn(id: durableTurnID)
        )

        let fixture = routingRepository.appending(
            path: "Tests/MillerLiveTests/Fixtures/fake-codex-app-server.mjs"
        )
        let typedMarker = root.appending(path: "typed.jsonl")
        let liveMarker = root.appending(path: "live.jsonl")
        let typedGateway = CodexTypedReasoningGateway(
            makeClient: {
                let process = CodexAppServerProcess(configuration: try .init(
                    executableURL: routingNode,
                    arguments: [
                        fixture.path, "typed-portable-skill-routing-proof",
                        typedMarker.path,
                    ],
                    temporaryParentURL: root,
                    terminationGrace: .milliseconds(100),
                    cleanupPendingDelay: .milliseconds(100)
                ))
                return CodexAppServerClient(process: process)
            },
            credential: {
                .init(
                    accessToken: Data("synthetic".utf8),
                    accountID: "account-1", planType: "plus"
                )
            },
            model: { "gpt-5.6-terra" }, cwd: root.path,
            timeout: .seconds(5)
        )
        let supervisor = GatewaySupervisor(configuration: .init(
            executableURL: routingNode,
            arguments: [
                routingRepository.appending(path: "Gateway/src/fake-helper.mjs").path,
                "portable-skill-routing-proof",
            ],
            workingDirectoryURL: routingRepository,
            environment: [
                "LANG": "C", "LC_ALL": "C", "TMPDIR": root.path,
            ],
            terminationGrace: .milliseconds(100)
        ))
        defer { Task { await supervisor.shutdown() } }
        let compatibleGateway = JSONLReasoningGateway(
            supervisor: supervisor,
            selectedProvider: {
                GatewayProviderProfile(
                    kind: "openai_compatible", baseURL: deepSeek.baseURL,
                    model: deepSeek.model,
                    credentialReference: deepSeek.credentialReference
                )
            }
        )
        let selection = PortableSkillProfileSelection(codex)
        let router = ProviderRoutingGateway(
            selectedKind: { await selection.profile.kind },
            codex: typedGateway, openAICompatible: compatibleGateway
        )
        let gateway = CapabilityReasoningGateway(
            base: router, selectedProfile: { await selection.profile },
            controller: controller
        )
        func runTyped(_ profile: ProviderProfile, generation: Int) async throws -> String {
            await selection.set(profile)
            let stream = try await gateway.start(.init(
                conversationID: ConversationID(), turnID: TurnID(),
                generation: generation, context: [], userText: "ordinary question"
            ))
            var text = ""
            for try await event in stream {
                if case let .textDelta(_, delta) = event { text += delta }
            }
            return text
        }

        #expect(try await runTyped(codex, generation: 1) == "hello")
        #expect(try await runTyped(deepSeek, generation: 2) == "portable")
        try await runLiveSkillSession(
            root: root, marker: liveMarker, fixture: fixture,
            profile: codex, controller: controller,
            expectsSkill: true, expectsVisibleOmission: true
        )

        try await controller.setPortableSkillEnabledFromSettings(
            false, skillID: skill.id, providerProfileID: codex.id
        )
        #expect(try await runTyped(codex, generation: 3) == "hello")
        try await runLiveSkillSession(
            root: root, marker: liveMarker, fixture: fixture,
            profile: codex, controller: controller,
            expectsSkill: false, expectsVisibleOmission: false
        )

        try await controller.setPortableSkillEnabledFromSettings(
            false, skillID: skill.id, providerProfileID: deepSeek.id
        )
        #expect(try await runTyped(deepSeek, generation: 4) == "ordinary")

        try await controller.setPortableSkillEnabledFromSettings(
            true, skillID: skill.id, providerProfileID: codex.id
        )
        try await controller.setPortableSkillEnabledFromSettings(
            true, skillID: skill.id, providerProfileID: deepSeek.id
        )
        try await controller.deletePortableSkillFromSettings(id: skill.id)
        #expect(try await runTyped(codex, generation: 5) == "hello")
        #expect(try await runTyped(deepSeek, generation: 6) == "ordinary")
        try await runLiveSkillSession(
            root: root, marker: liveMarker, fixture: fixture,
            profile: codex, controller: controller,
            expectsSkill: false, expectsVisibleOmission: false
        )
        await supervisor.shutdown()

        let typedRequests = try routingRequests(at: typedMarker)
        let typedTurns = typedRequests.filter { $0["method"] as? String == "turn/start" }
        #expect(typedTurns.count == 3)
        #expect(try routingInputs(in: typedTurns[0]).map { $0["type"] as? String }
            == ["text", "skill"])
        #expect(try routingInputs(in: typedTurns[1]).map { $0["type"] as? String }
            == ["text"])
        #expect(try routingInputs(in: typedTurns[2]).map { $0["type"] as? String }
            == ["text"])
        let typedSkill = try #require(try routingInputs(in: typedTurns[0]).last)
        let typedSkillPath = try #require(typedSkill["path"] as? String)
        #expect(!FileManager.default.fileExists(atPath: typedSkillPath))
        let typedSkillRoot = URL(fileURLWithPath: typedSkillPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: typedSkillRoot.path))
        let typedRoots = typedRequests.filter {
            $0["method"] as? String == "skills/extraRoots/set"
        }
        #expect(typedRoots.count == 1)
        #expect(typedRequests.filter { $0["method"] as? String == "skills/list" }.count == 1)

        let liveRequests = try routingRequests(at: liveMarker)
        let liveStarts = liveRequests.filter {
            $0["method"] as? String == "thread/realtime/start"
        }
        #expect(liveStarts.count == 3)
        #expect(try routingPrompt(in: liveStarts[0]).contains("Portable skill"))
        #expect(!((try routingPrompt(in: liveStarts[1])).contains("Portable skill")))
        #expect(!((try routingPrompt(in: liveStarts[2])).contains("Portable skill")))
        #expect(liveRequests.filter {
            $0["method"] as? String == "skills/extraRoots/set"
        }.count == 1)
        #expect(liveRequests.filter { $0["method"] as? String == "skills/list" }.count == 1)

        let reopened = try SQLiteConversationRepository(path: databasePath)
        #expect(try await reopened.turn(id: durableTurnID) == durableTurnBeforeMutation)
        #expect(try await repository.skills().isEmpty)
    }
}

private actor PortableSkillProfileSelection {
    private(set) var profile: ProviderProfile
    init(_ profile: ProviderProfile) { self.profile = profile }
    func set(_ profile: ProviderProfile) { self.profile = profile }
}

@MainActor
private func runLiveSkillSession(
    root: URL,
    marker: URL,
    fixture: URL,
    profile: ProviderProfile,
    controller capabilityController: CapabilityController,
    expectsSkill: Bool,
    expectsVisibleOmission: Bool
) async throws {
    let helper = root.appending(path: "live-helper-\(UUID().uuidString)")
    try Data(
        "#!/bin/sh\nexec \(routingNode.path) \(fixture.path) portable-skill-live-routing-proof \(marker.path)\n".utf8
    ).write(to: helper)
    #expect(chmod(helper.path, 0o700) == 0)
    let envelope = try CredentialEnvelope(
        providerKind: .codexOAuth,
        payload: Data(
            #"{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":null,"accountId":"account-1"}"#.utf8
        )
    )
    let liveController = try GPTLiveController(
        helperURL: helper, temporaryParentURL: root,
        selectedProfile: { profile },
        credentialLoader: GPTLiveCredentialLoader(load: { _ in envelope }),
        refreshCredential: {}, microphonePermission: { .authorized },
        portableSkillAttachment: { providerID in
            guard let attachment = try await capabilityController
                .selectedSkillAttachment(providerProfileID: providerID)
            else { return nil }
            return try PortableSkillAttachment(
                skills: attachment.skills,
                omittedCount: attachment.omittedCount + 1
            )
        },
        makePeer: { PortableSkillRoutingPeer() },
        helperVerifier: { _ in }, spawnedProcessVerifier: { _ in }
    )
    let base = liveController.dependencies()
    let model = AppPresentationModel(
        dependencies: routingHostDependencies,
        liveVoice: LiveVoiceDependencies(
            initialAvailability: .available, availability: base.availability,
            start: base.start, mute: base.mute,
            interrupt: base.interrupt, end: base.end
        )
    )
    let previousRoots = Set(try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("miller-skills-") })
    let run = Task { await model.startLiveVoice() }
    try await routingWaitUntil { model.voiceState == .listening }
    if expectsVisibleOmission {
        #expect(model.voiceStatusText
            == "Listening — some enabled skills were omitted to stay within limits")
    } else {
        #expect(model.voiceStatusText == "Listening")
    }
    let activeRoots = Set(try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("miller-skills-") })
        .subtracting(previousRoots)
    #expect(activeRoots.count == (expectsSkill ? 1 : 0))
    if let activeRoot = activeRoots.first {
        let skillsRoot = activeRoot.appending(path: "skills")
        let skillDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: skillsRoot, includingPropertiesForKeys: nil
            ).first
        )
        let skillFile = skillDirectory.appending(path: "SKILL.md")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: skillFile.path
        )
        let mode = attributes[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
    await model.endLiveVoice()
    await run.value
    for activeRoot in activeRoots {
        #expect(!FileManager.default.fileExists(atPath: activeRoot.path))
    }
}

private let routingRepository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let routingNode = URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin/node")
private let routingHostDependencies = HostDependencies(
    submit: { _, _ in TurnID() }, stop: {},
    loadTurn: { _ in nil }, loadConversations: { [] }, loadTurns: { _ in [] },
    archive: { _ in }, unarchive: { _ in }, delete: { _ in }
)

private func routingRequests(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try #require(
            JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        )
    }
}

private func routingInputs(in request: [String: Any]) throws -> [[String: Any]] {
    let params = try #require(request["params"] as? [String: Any])
    return try #require(params["input"] as? [[String: Any]])
}

private func routingPrompt(in request: [String: Any]) throws -> String {
    let params = try #require(request["params"] as? [String: Any])
    return try #require(params["prompt"] as? String)
}

@MainActor
private func routingWaitUntil(
    _ predicate: @MainActor () -> Bool
) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PortableSkillRoutingTestError.timeout
}

private enum PortableSkillRoutingTestError: Error { case timeout }

@MainActor
private final class PortableSkillRoutingPeer: LiveAudioPeer {
    func prepareOffer() async throws -> String { portableSkillRoutingOffer }
    func applyAnswerAndWaitForConnected(_ answer: String) async throws {}
    func setMuted(_ muted: Bool) async throws {}
    func close() async {}
}

private let portableSkillRoutingOffer = """
v=0\r
o=- 0 0 IN IP4 0.0.0.0\r
s=-\r
t=0 0\r
a=group:BUNDLE 0 1\r
m=audio 9 UDP/TLS/RTP/SAVPF 111\r
a=mid:0\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=rtpmap:111 opus/48000/2\r
m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
a=mid:1\r
a=ice-ufrag:u\r
a=ice-pwd:p\r
a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r
a=setup:actpass\r
a=sctp-port:5000\r
a=max-message-size:262144\r
"""
