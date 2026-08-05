import AppKit
import MillerCore
import Testing
@testable import MillerApp

@Suite(.serialized)
@MainActor
struct OverlayLiveVoicePresentationTests {
    @Test(arguments: OverlayDismissalEntryPoint.allCases)
    fileprivate func activeVoiceDismissalWaitsForTheSharedEndCleanupBeforeHiding(
        entryPoint: OverlayDismissalEntryPoint
    ) async throws {
        let probe = OverlayDismissCleanupProbe()
        let model = AppPresentationModel(
            dependencies: hostDependencies(),
            liveVoice: await probe.dependencies(initialAvailability: .listening)
        )
        let controller = OverlayPanelController(model: model)
        controller.show()
        try await waitUntil { controller.window?.isVisible == true }

        entryPoint.dismiss(controller)
        try await waitUntil { await probe.endEntered }
        // Escape/status-toggle/window-close all reach the same controller
        // method; a second dismissal must join, not hide early or end twice.
        controller.dismissAfterLiveVoiceCleanup()

        #expect(controller.window?.isVisible == true)
        await probe.releaseEnd()
        try await waitUntil { controller.window?.isVisible == false }
        #expect(model.voiceState == .closed)
        #expect(await probe.endCalls == 1)
    }

    @Test
    func inactiveOverlayDismissalHidesImmediatelyWithoutEndingVoice() async throws {
        let probe = OverlayDismissCleanupProbe()
        let model = AppPresentationModel(
            dependencies: hostDependencies(),
            liveVoice: await probe.dependencies(initialAvailability: .available)
        )
        let controller = OverlayPanelController(model: model)
        controller.show()
        try await waitUntil { controller.window?.isVisible == true }

        controller.dismissAfterLiveVoiceCleanup()

        try await waitUntil { controller.window?.isVisible == false }
        #expect(await probe.endCalls == 0)
    }

    private func hostDependencies() -> HostDependencies {
        HostDependencies(
            submit: { _, _ in TurnID() },
            stop: {},
            loadTurn: { _ in nil },
            loadConversations: { [] },
            loadTurns: { _ in [] },
            archive: { _ in },
            unarchive: { _ in },
            delete: { _ in }
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                throw OverlayPresentationTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum OverlayDismissalEntryPoint: CaseIterable {
    case escape
    case statusToggle
    case windowClose

    static var allCases: [Self] { [.escape, .statusToggle, .windowClose] }

    @MainActor
    func dismiss(_ controller: OverlayPanelController) {
        switch self {
        case .escape:
            controller.dismissAfterLiveVoiceCleanup()
        case .statusToggle:
            controller.toggle()
        case .windowClose:
            guard let window = controller.window else { return }
            _ = controller.windowShouldClose(window)
        }
    }
}

private enum OverlayPresentationTestError: Error {
    case timeout
}

private actor OverlayDismissCleanupProbe {
    private var entered = false
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    var endEntered: Bool { entered }
    var endCalls: Int { calls }

    func dependencies(initialAvailability: LiveVoiceState) -> LiveVoiceDependencies {
        LiveVoiceDependencies(
            initialAvailability: initialAvailability,
            availability: { .available },
            start: { _ in },
            mute: { _ in },
            interrupt: {},
            end: { [self] in await waitForEnd() }
        )
    }

    private func waitForEnd() async {
        calls += 1
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func releaseEnd() {
        continuation?.resume()
        continuation = nil
    }
}
