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
    func attachesOnlyEnabledProviderSkillsAndDeletionAffectsOnlyFutureRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "miller-portable-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try SQLiteCapabilityRepository(path: root.appending(path: "db.sqlite3").path)
        let provider = UUID(), other = UUID()
        let profileRepository = try SQLiteConversationRepository(
            path: root.appending(path: "db.sqlite3").path
        )
        try await profileRepository.saveProviderProfile(try ProviderProfile(
            id: provider, kind: .openAICompatible, label: "Selected",
            baseURL: "https://example.invalid", model: "fixture"
        ))
        try await profileRepository.saveProviderProfile(try ProviderProfile(
            id: other, kind: .openAICompatible, label: "Other",
            baseURL: "https://other.example.invalid", model: "fixture"
        ))
        let now = Date()
        let skill = PortableSkillRecord(
            id: "skill-example", pluginID: nil, name: "Example",
            description: "Example instructions", markdownSnapshot: "Do the example.",
            sourceHash: String(repeating: "a", count: 64), enabled: false,
            createdAt: now, updatedAt: now
        )
        try await repository.saveSkill(skill)
        try await repository.setSkillEnabled(true, skillID: skill.id, providerProfileID: provider)
        let controller = CapabilityController(
            loadConfiguration: { .init(servers: [], toolPolicies: [:]) },
            settingsRepository: repository
        )
        await controller.start()
        let original = ReasoningRequest(
            conversationID: ConversationID(), turnID: TurnID(), generation: 1,
            context: [], userText: "hello"
        )

        let selected = try await controller.prepareRequest(
            original, providerProfileID: provider, kind: .openAICompatible
        )
        #expect(selected.portableSkillAttachment?.skills.map(\.id) == [skill.id])
        await controller.finishTypedAssociation(turnID: original.turnID, generation: 1)

        let different = ReasoningRequest(
            conversationID: original.conversationID, turnID: TurnID(), generation: 2,
            context: [], userText: "hello again"
        )
        let excluded = try await controller.prepareRequest(
            different, providerProfileID: other, kind: .openAICompatible
        )
        #expect(excluded.portableSkillAttachment == nil)
        await controller.finishTypedAssociation(turnID: different.turnID, generation: 2)

        try await repository.deleteSkill(id: skill.id)
        let afterDelete = ReasoningRequest(
            conversationID: original.conversationID, turnID: TurnID(), generation: 3,
            context: [], userText: "third"
        )
        let absent = try await controller.prepareRequest(
            afterDelete, providerProfileID: provider, kind: .openAICompatible
        )
        #expect(absent.portableSkillAttachment == nil)
        #expect(selected.portableSkillAttachment?.skills.map(\.id) == [skill.id])
    }
}
