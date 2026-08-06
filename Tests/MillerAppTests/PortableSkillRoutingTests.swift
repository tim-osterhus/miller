import Foundation
import MillerCore
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
    func productionRoutingProjectsOneSkillPerProviderAndDeletionIsProspective() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "miller-portable-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(path: root.appending(path: "db.sqlite3").path)
        let codex = try ProviderProfile(
            kind: .codexOAuth, label: "Codex", baseURL: nil,
            model: "gpt-5.6-terra"
        )
        let deepSeek = try ProviderProfile(
            kind: .openAICompatible, label: "DeepSeek",
            baseURL: "https://api.deepseek.com", model: "deepseek-chat"
        )
        let profileRepository = try SQLiteConversationRepository(
            path: root.appending(path: "db.sqlite3").path
        )
        try await profileRepository.saveProviderProfile(codex)
        try await profileRepository.saveProviderProfile(deepSeek)
        let now = Date()
        let skill = PortableSkillRecord(
            id: "skill-example", pluginID: nil, name: "Example",
            description: "Example instructions", markdownSnapshot: "Do the example.",
            sourceHash: String(repeating: "a", count: 64), enabled: false,
            createdAt: now, updatedAt: now
        )
        try await repository.saveSkill(skill)
        try await repository.setSkillEnabled(
            true, skillID: skill.id, providerProfileID: codex.id
        )
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )
        await controller.start()
        let selection = PortableSkillProfileSelection(codex)
        let codexProbe = PortableSkillGatewayProbe()
        let piProbe = PortableSkillGatewayProbe()
        let router = ProviderRoutingGateway(
            selectedKind: { await selection.profile.kind },
            codex: codexProbe, openAICompatible: piProbe
        )
        let gateway = CapabilityReasoningGateway(
            base: router, selectedProfile: { await selection.profile },
            controller: controller
        )
        func run(_ generation: Int) async throws {
            let stream = try await gateway.start(.init(
                conversationID: ConversationID(), turnID: TurnID(),
                generation: generation, context: [], userText: "hello"
            ))
            for try await _ in stream {}
        }

        try await run(1)
        let firstCodex = try #require(await codexProbe.requests.first)
        #expect(firstCodex.portableSkillAttachment?.skills.map(\.id) == [skill.id])
        #expect(await piProbe.requests.isEmpty)

        await selection.set(deepSeek)
        try await run(2)
        #expect(try #require(await piProbe.requests.last).portableSkillAttachment == nil)

        try await repository.setSkillEnabled(
            true, skillID: skill.id, providerProfileID: deepSeek.id
        )
        try await run(3)
        #expect(try #require(await piProbe.requests.last)
            .portableSkillAttachment?.skills.map(\.id) == [skill.id])

        try await repository.setSkillEnabled(
            false, skillID: skill.id, providerProfileID: deepSeek.id
        )
        try await run(4)
        #expect(try #require(await piProbe.requests.last).portableSkillAttachment == nil)

        try await repository.deleteSkill(id: skill.id)
        await selection.set(codex)
        try await run(5)
        #expect(try #require(await codexProbe.requests.last).portableSkillAttachment == nil)
        #expect(firstCodex.portableSkillAttachment?.skills.map(\.id) == [skill.id])
    }
}

private actor PortableSkillProfileSelection {
    private(set) var profile: ProviderProfile
    init(_ profile: ProviderProfile) { self.profile = profile }
    func set(_ profile: ProviderProfile) { self.profile = profile }
}

private actor PortableSkillGatewayProbe: ReasoningGateway {
    private(set) var requests: [ReasoningRequest] = []

    func start(
        _ request: ReasoningRequest
    ) async throws -> AsyncThrowingStream<ReasoningEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.accepted)
            continuation.yield(.completed)
            continuation.finish()
        }
    }

    func cancel(_ cancellation: ReasoningCancellation) async { _ = cancellation }
}
