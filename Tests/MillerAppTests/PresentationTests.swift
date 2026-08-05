import Foundation
import MillerCore
import Testing
@testable import MillerApp

@Suite
@MainActor
struct PresentationTests {
    @Test
    func assistantMarkdownRendersFormattingWhilePreservingText() {
        let rendered = AssistantMarkdown.attributedString(
            "**Bold** and [linked](https://example.com)."
        )

        #expect(String(rendered.characters) == "Bold and linked.")
        #expect(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(rendered.runs.contains { $0.link != nil })
    }

    @Test
    func assistantMarkdownPreservesBlockStructure() {
        let blocks = AssistantMarkdown.blocks(
            "# Heading\n\n- First\n2. Second\n> Quoted\n```swift\nlet value = 1\n```"
        )

        #expect(blocks == [
            .heading(level: 1, text: "Heading"),
            .spacer,
            .unorderedItem("First"),
            .orderedItem(marker: "2.", text: "Second"),
            .quote("Quoted"),
            .code(language: "swift", text: "let value = 1"),
        ])
    }

    @Test
    func menuStateReflectsActiveTurn() {
        #expect(
            MenuState.derive(activeTurn: false)
                == MenuState(canCreateConversation: true, canStop: false)
        )
        #expect(
            MenuState.derive(activeTurn: true)
                == MenuState(canCreateConversation: false, canStop: true)
        )
    }

    @Test
    func presentationStateDerivesFromDurableTurn() {
        #expect(
            PresentationDerivation.state(for: turn(state: .accepted))
                == .waiting
        )
        #expect(
            PresentationDerivation.state(
                for: turn(state: .streaming, assistantText: "partial")
            ) == .responding
        )
        #expect(
            PresentationDerivation.state(for: turn(state: .stopped))
                == .stopped
        )
        #expect(
            PresentationDerivation.state(for: turn(state: .failed))
                == .failed
        )
    }

    @Test
    func conversationListOrdersActiveBeforeArchivedThenNewestFirst() {
        let now = Date()
        let older = now.addingTimeInterval(-60)
        let values = [
            item(state: .archived, updatedAt: now),
            item(state: .active, updatedAt: older),
            item(state: .active, updatedAt: now),
        ]

        let ordered = ConversationListItem.ordered(values)

        #expect(ordered.map(\.state) == [.active, .active, .archived])
        #expect(ordered.map(\.updatedAt) == [now, older, now])
    }

    @Test
    func overlaySubmitDisablesSecondSubmitAndStopClearsActiveTurn() async {
        let probe = CallProbe()
        let activeID = TurnID()
        let model = AppPresentationModel(
            dependencies: dependencies(
                submit: { _, _ in
                    await probe.recordSubmit()
                    return activeID
                },
                stop: {
                    await probe.recordStop()
                },
                loadTurn: { _ in nil }
            )
        )
        model.draft = "hello"

        await model.submit()
        model.draft = "second"
        await model.submit()

        let submitCount = await probe.submitCount
        #expect(model.isActiveTurn)
        #expect(!model.canSubmit)
        #expect(submitCount == 1)

        await model.stop()

        let stopCount = await probe.stopCount
        #expect(!model.isActiveTurn)
        #expect(model.presentationState == .stopped)
        #expect(stopCount == 1)
    }

    @Test
    func activeTurnRefusesNewConversation() async {
        let activeID = TurnID()
        let model = AppPresentationModel(
            dependencies: dependencies(
                submit: { _, _ in activeID },
                loadTurn: { _ in nil }
            )
        )
        let original = model.selectedConversationID
        model.draft = "hello"
        await model.submit()

        model.newConversation()

        #expect(model.selectedConversationID == original)
    }

    @Test
    func shortcutFailureDoesNotDisableMenuPresentation() {
        let model = AppPresentationModel(dependencies: dependencies())
        model.setShortcutAvailable(false)

        #expect(!model.shortcutAvailable)
        #expect(model.menuState.canCreateConversation)
    }

    @Test
    func shortcutSelectionRegistersAndUpdatesAvailability() {
        let model = AppPresentationModel(dependencies: dependencies())
        var registrations: [GlobalShortcut] = []
        model.configureShortcut(.commandShiftSpace) { shortcut in
            registrations.append(shortcut)
            return shortcut != .optionShiftSpace
        }

        model.selectShortcut(.controlShiftSpace)

        #expect(registrations == [.controlShiftSpace])
        #expect(model.selectedShortcut == .controlShiftSpace)
        #expect(model.shortcutAvailable)

        model.selectShortcut(.optionShiftSpace)

        #expect(registrations == [
            .controlShiftSpace,
            .optionShiftSpace,
        ])
        #expect(model.selectedShortcut == .optionShiftSpace)
        #expect(!model.shortcutAvailable)
        #expect(model.menuState.canCreateConversation)
    }

    @Test
    func providerSwitchingIsRefusedWhileTurnIsActive() async {
        let probe = ProviderSettingsProbe()
        let profileID = UUID()
        let activeID = TurnID()
        let model = AppPresentationModel(
            dependencies: dependencies(
                submit: { _, _ in activeID },
                loadTurn: { _ in nil }
            ),
            providerSettings: await probe.dependencies()
        )
        model.draft = "hello"
        await model.submit()

        await model.selectProvider(profileID)

        #expect(await probe.selections == [])
        #expect(model.providerStatus == "Finish the active response before switching.")
    }

    @Test
    func invalidEndpointIsRejectedBeforeCredentialStorage() async {
        let probe = ProviderSettingsProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )

        await model.saveOpenAICompatibleProfile(
            label: "DeepSeek",
            endpoint: "http://example.com",
            model: "deepseek-chat",
            apiKey: "synthetic"
        )

        #expect(await probe.savedProfiles == [])
        #expect(model.providerStatus == "Endpoint is not allowed.")
    }

    @Test
    func editedProviderRetainsTheRequestedProfileIdentity() async {
        let probe = ProviderSettingsProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )
        let profileID = UUID()

        await model.saveOpenAICompatibleProfile(
            profileID: profileID,
            label: "DeepSeek",
            endpoint: "https://example.invalid",
            model: "deepseek-chat",
            apiKey: ""
        )

        #expect(await probe.savedProfiles.map(\.profileID) == [profileID])
    }

    @Test
    func activeTurnRefusesAllProviderMutations() async {
        let probe = ProviderSettingsProbe()
        let activeID = TurnID()
        let model = AppPresentationModel(
            dependencies: dependencies(
                submit: { _, _ in activeID },
                loadTurn: { _ in nil }
            ),
            providerSettings: await probe.dependencies()
        )
        model.draft = "hello"
        await model.submit()

        await model.prepareCodexLogin()
        await model.refreshCodexAuthentication()
        await model.selectCodexModel("gpt-5.4")
        await model.localProviderLogout()
        await model.deleteProvider(UUID())

        #expect(await probe.authenticationActions == [])
        #expect(await probe.deletedProfiles == [])
        #expect(model.providerStatus == "Finish the active response before deleting.")
    }

    @Test
    func codexModelSelectionPersistsPackagedAndCustomIDsThroughOneDependency() async {
        let probe = ProviderSettingsProbe()
        let model = AppPresentationModel(
            dependencies: dependencies(),
            providerSettings: await probe.dependencies()
        )

        await model.selectCodexModel("gpt-5.4")
        await model.selectCodexModel("org/custom-model")

        #expect(await probe.codexModels == ["gpt-5.4", "org/custom-model"])
    }

    private func dependencies(
        submit: @escaping @Sendable (String, ConversationID) async throws -> TurnID = {
            _, _ in TurnID()
        },
        stop: @escaping @Sendable () async throws -> Void = {},
        loadTurn: @escaping @Sendable (TurnID) async throws -> Turn? = { _ in nil }
    ) -> HostDependencies {
        HostDependencies(
            submit: submit,
            stop: stop,
            loadTurn: loadTurn,
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    private func turn(
        state: TurnState,
        assistantText: String = ""
    ) -> Turn {
        Turn(
            id: TurnID(),
            conversationID: ConversationID(),
            sequence: 1,
            inputMode: .text,
            userText: "user",
            assistantText: assistantText,
            state: state,
            generation: state.isTerminal ? 2 : 1,
            errorCode: state == .failed ? "failed" : nil,
            errorMessage: state == .failed ? "The request failed." : nil,
            startedAt: Date(),
            terminalAt: state.isTerminal ? Date() : nil
        )
    }

    private func item(
        state: ConversationState,
        updatedAt: Date
    ) -> ConversationListItem {
        ConversationListItem(
            Conversation(
                id: ConversationID(),
                title: "Conversation",
                state: state,
                createdAt: updatedAt,
                updatedAt: updatedAt,
                archivedAt: state == .archived ? updatedAt : nil
            )
        )
    }
}

private actor ProviderSettingsProbe {
    private(set) var selections: [UUID] = []
    private(set) var savedProfiles: [ProviderSettingsInput] = []
    private(set) var authenticationActions: [String] = []
    private(set) var deletedProfiles: [UUID] = []
    private(set) var codexModels: [String] = []

    func dependencies() -> ProviderSettingsDependencies {
        ProviderSettingsDependencies(
            load: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            saveOpenAICompatible: { [weak self] input, _ in
                await self?.record(input)
            },
            saveCodexModel: { [weak self] model in
                await self?.recordCodexModel(model)
            },
            select: { [weak self] id, _ in
                await self?.record(id)
            },
            beginCodexLogin: { [weak self] _ in
                await self?.recordAuthentication("begin")
            },
            refreshCodexAuthentication: { [weak self] _ in
                await self?.recordAuthentication("refresh")
            },
            retryReadiness: {
                ProviderSettingsSnapshot(profiles: [], readiness: "Not configured")
            },
            localLogout: { [weak self] _ in
                await self?.recordAuthentication("logout")
            },
            delete: { [weak self] id, _ in
                await self?.recordDeletion(id)
            },
            reset: { ResetResult(roots: []) }
        )
    }

    private func record(_ input: ProviderSettingsInput) {
        savedProfiles.append(input)
    }

    private func record(_ id: UUID) {
        selections.append(id)
    }

    private func recordCodexModel(_ model: String) {
        codexModels.append(model)
    }

    private func recordAuthentication(_ action: String) {
        authenticationActions.append(action)
    }

    private func recordDeletion(_ id: UUID) {
        deletedProfiles.append(id)
    }
}

private actor CallProbe {
    private(set) var submitCount = 0
    private(set) var stopCount = 0

    func recordSubmit() {
        submitCount += 1
    }

    func recordStop() {
        stopCount += 1
    }
}
