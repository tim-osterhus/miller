import Foundation
import Testing
@testable import MillerApp

@Suite(.serialized)
struct CodexRuntimeSelectionTests {
    @Test
    func savedSelectionPrecedesAutomaticCandidates() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let saved = try fixture.executable(named: "saved-codex")
        let automatic = try fixture.executable(named: "automatic-codex")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [automatic],
            verify: { _ in }
        )

        let selection = try #require(resolver.resolve(savedPath: saved.path))

        #expect(selection.executableURL == saved.resolvingSymlinksInPath())
        #expect(selection.source == .saved)
    }

    @Test
    func invalidSavedSelectionFallsBackToAutomaticCandidate() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let automatic = try fixture.executable(named: "automatic-codex")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [automatic],
            verify: { _ in }
        )

        let selection = try #require(resolver.resolve(
            savedPath: fixture.root.appendingPathComponent("missing").path
        ))

        #expect(selection.executableURL == automatic.resolvingSymlinksInPath())
        #expect(selection.source == .automatic)
    }

    @Test
    func runtimeProjectionDistinguishesMissingFromRejectedExecutable() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("missing-codex")
        let missingResolver = CodexRuntimeResolver(
            automaticCandidates: [missing],
            verify: { _ in }
        )
        #expect(missingResolver.resolveReadiness(savedPath: nil) == .missing)

        let rejected = try fixture.executable(named: "rejected-codex")
        let rejectedResolver = CodexRuntimeResolver(
            automaticCandidates: [rejected],
            verify: { _ in throw CodexRuntimeSelectionError.invalidCandidate }
        )
        #expect(rejectedResolver.resolveReadiness(savedPath: nil) == .rejected)
    }

    @Test
    func npmLauncherResolvesToPlatformNativeExecutable() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let launcher = try fixture.npmLauncher()
        let expected = fixture.npmNativeExecutable
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [],
            verify: { _ in }
        )

        let selection = try resolver.resolveCandidate(launcher, source: .saved)

        #expect(selection.executableURL == expected.resolvingSymlinksInPath())
        #expect(selection.launcherURL == launcher.standardizedFileURL)
    }

    @Test
    func malformedNpmLauncherIsRejected() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let launcher = try fixture.executable(named: "codex.js")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [],
            verify: { _ in }
        )

        #expect(throws: CodexRuntimeSelectionError.invalidCandidate) {
            try resolver.resolveCandidate(launcher, source: .saved)
        }
    }

    @Test
    func verifierRejectionSkipsCandidateWithoutLaunchingIt() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let rejected = try fixture.executable(named: "rejected-codex")
        let accepted = try fixture.executable(named: "accepted-codex")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [rejected, accepted],
            verify: { url in
                if url.lastPathComponent == "rejected-codex" {
                    throw CodexRuntimeSelectionError.invalidCandidate
                }
            }
        )

        let selection = try #require(resolver.resolve(savedPath: nil))

        #expect(selection.executableURL == accepted.resolvingSymlinksInPath())
    }

    @Test
    func preferencesStoreAndClearOnlyTheSelectedPath() throws {
        let suite = "miller-codex-runtime-tests-\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CodexRuntimePreferences(defaults: defaults)

        preferences.save(path: "/tmp/codex")
        #expect(preferences.loadPath() == "/tmp/codex")

        preferences.clear()
        #expect(preferences.loadPath() == nil)
    }

    @Test
    func appLaunchUsesAutomaticExternalRuntimeWithoutACommandLineOverride() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let automatic = try fixture.executable(named: "automatic-codex")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [automatic],
            verify: { _ in }
        )

        let resolved = try AppCoordinator.liveRuntimeSelection(
            arguments: ["Miller"],
            savedPath: nil,
            resolver: resolver
        )
        let selection = try #require(resolved)

        #expect(selection.source == .automatic)
        #expect(selection.executableURL == automatic.resolvingSymlinksInPath())
    }

    @Test
    func explicitDevelopmentOverridePrecedesSavedAndAutomaticPaths() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let explicit = try fixture.executable(named: "explicit-codex")
        let saved = try fixture.executable(named: "saved-codex")
        let automatic = try fixture.executable(named: "automatic-codex")
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [automatic],
            verify: { _ in }
        )

        let resolved = try AppCoordinator.liveRuntimeSelection(
            arguments: ["Miller", "--gpt-live-app-server", explicit.path],
            savedPath: saved.path,
            resolver: resolver
        )
        let selection = try #require(resolved)

        #expect(selection.source == .developmentOverride)
        #expect(selection.executableURL == explicit.resolvingSymlinksInPath())
    }

    @Test
    func appLaunchWithoutAnInstalledRuntimeReturnsUnavailableSelection() throws {
        let resolver = CodexRuntimeResolver(
            automaticCandidates: [],
            verify: { _ in }
        )

        #expect(try AppCoordinator.liveRuntimeSelection(
            arguments: ["Miller"],
            savedPath: nil,
            resolver: resolver
        ) == nil)
    }

    @Test
    @MainActor
    func settingsModelReportsRejectedRuntimeInsteadOfNotInstalled() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let rejected = try fixture.executable(named: "rejected-codex")
        let suite = "miller-codex-runtime-settings-rejected-\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CodexRuntimePreferences(defaults: defaults)
        preferences.save(path: rejected.path)

        let model = CodexRuntimeSettingsModel(
            preferences: preferences,
            resolver: CodexRuntimeResolver(
                automaticCandidates: [],
                verify: { _ in throw CodexRuntimeSelectionError.invalidCandidate }
            )
        )

        #expect(model.displayPath == nil)
        #expect(model.status == "Unsupported Codex executable")
    }

    @Test
    @MainActor
    func clearingSelectionReportsRejectedAutomaticRuntimeInsteadOfNotInstalled() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let selected = try fixture.executable(named: "selected-codex")
        let rejected = try fixture.executable(named: "rejected-codex")
        let suite = "miller-codex-runtime-settings-clear-rejected-\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CodexRuntimePreferences(defaults: defaults)
        preferences.save(path: selected.path)

        let model = CodexRuntimeSettingsModel(
            preferences: preferences,
            resolver: CodexRuntimeResolver(
                automaticCandidates: [rejected],
                verify: { url in
                    if url.lastPathComponent == "rejected-codex" {
                        throw CodexRuntimeSelectionError.invalidCandidate
                    }
                }
            )
        )

        model.clear()

        #expect(preferences.loadPath() == nil)
        #expect(model.displayPath == nil)
        #expect(model.status == "Unsupported Codex executable — relaunch Miller to apply")
        #expect(model.requiresRelaunch)
    }

    @Test
    @MainActor
    func settingsSelectionValidatesBeforeSavingAndRequestsRelaunch() throws {
        let fixture = try RuntimeSelectionFixture()
        defer { fixture.cleanup() }
        let executable = try fixture.executable(named: "codex")
        let suite = "miller-codex-runtime-settings-\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CodexRuntimePreferences(defaults: defaults)
        let model = CodexRuntimeSettingsModel(
            preferences: preferences,
            resolver: CodexRuntimeResolver(
                automaticCandidates: [],
                verify: { _ in }
            )
        )

        try model.choose(executable)

        #expect(preferences.loadPath() == executable.path)
        #expect(model.requiresRelaunch)
        #expect(model.status == "Selected — relaunch Miller to apply")

        model.clear()
        #expect(preferences.loadPath() == nil)
        #expect(model.requiresRelaunch)
    }
}

private struct RuntimeSelectionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "miller-codex-runtime-selection-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var npmNativeExecutable: URL {
        root
            .appendingPathComponent("lib/node_modules/@openai/codex")
            .appendingPathComponent("node_modules/@openai/codex-darwin-arm64")
            .appendingPathComponent("vendor/aarch64-apple-darwin/bin/codex")
    }

    func executable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url)
        #expect(chmod(url.path, 0o700) == 0)
        return url
    }

    func npmLauncher() throws -> URL {
        let packageRoot = root.appendingPathComponent("lib/node_modules/@openai/codex")
        let script = packageRoot.appendingPathComponent("bin/codex.js")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/usr/bin/env node\n".utf8).write(to: script)
        #expect(chmod(script.path, 0o700) == 0)
        _ = try executable(at: npmNativeExecutable)

        let launcher = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: launcher.path,
            withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js"
        )
        return launcher
    }

    private func executable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url)
        #expect(chmod(url.path, 0o700) == 0)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
