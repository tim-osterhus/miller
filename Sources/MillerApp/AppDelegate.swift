import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var terminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !MILLER_RELEASE_BUILD
        if Self.runNoninteractiveHarnessModeIfRequested(
            ProcessInfo.processInfo.arguments
        ) {
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
        do {
            let coordinator = try AppCoordinator(
                environment: ProcessInfo.processInfo.environment
            )
            self.coordinator = coordinator
            coordinator.start()
            coordinator.showPrimaryInterface()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Miller could not start"
            alert.informativeText = "Storage or the local helper is unavailable."
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    #if !MILLER_RELEASE_BUILD
    private static func runNoninteractiveHarnessModeIfRequested(
        _ arguments: [String]
    ) -> Bool {
        let output: String?
        if arguments.contains("--gpt-live-operator-cleanup-test") {
            output = "GPT_LIVE_OPERATOR_CLEANUP_OK\n"
        } else if arguments.contains("--gpt-live-harness-smoke-test"),
                  !arguments.contains("--gpt-live-app-server") {
            output = "GPT_LIVE_HARNESS_SMOKE_TEXT_ONLY\n"
        } else {
            output = nil
        }
        guard let output else { return false }
        FileHandle.standardOutput.write(Data(output.utf8))
        return true
    }
    #endif

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        coordinator?.showPrimaryInterface()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending, let coordinator else {
            return .terminateNow
        }
        terminationReplyPending = true
        Task {
            await coordinator.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
