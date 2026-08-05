import Combine
import Foundation

enum CodexRuntimeSelectionError: Error, Equatable, Sendable {
    case invalidCandidate
}

enum CodexRuntimeSelectionSource: Equatable, Sendable {
    case developmentOverride
    case saved
    case automatic
}

struct CodexRuntimeSelection: Equatable, Sendable {
    let launcherURL: URL
    let executableURL: URL
    let source: CodexRuntimeSelectionSource
}

struct CodexRuntimeResolver: Sendable {
    typealias Verifier = @Sendable (URL) throws -> Void

    private let automaticCandidates: [URL]
    private let verify: Verifier

    init(
        automaticCandidates: [URL],
        verify: @escaping Verifier
    ) {
        self.automaticCandidates = automaticCandidates
        self.verify = verify
    }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        verify: @escaping Verifier
    ) {
        self.init(
            automaticCandidates: Self.defaultCandidates(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            verify: verify
        )
    }

    func resolve(savedPath: String?) -> CodexRuntimeSelection? {
        if let savedPath,
           let selected = try? resolveCandidate(
               URL(fileURLWithPath: savedPath),
               source: .saved
           )
        {
            return selected
        }
        for candidate in automaticCandidates {
            if let selected = try? resolveCandidate(candidate, source: .automatic) {
                return selected
            }
        }
        return nil
    }

    func resolveCandidate(
        _ candidate: URL,
        source: CodexRuntimeSelectionSource
    ) throws -> CodexRuntimeSelection {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw CodexRuntimeSelectionError.invalidCandidate
        }
        let launcher = candidate.standardizedFileURL
        let resolved = launcher.resolvingSymlinksInPath().standardizedFileURL
        let executable: URL
        if resolved.lastPathComponent == "codex.js" {
            let packageRoot = resolved
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            executable = packageRoot
                .appendingPathComponent("node_modules/@openai/codex-darwin-arm64")
                .appendingPathComponent("vendor/aarch64-apple-darwin/bin/codex")
                .resolvingSymlinksInPath()
                .standardizedFileURL
        } else {
            executable = resolved
        }
        guard executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw CodexRuntimeSelectionError.invalidCandidate }
        try verify(executable)
        return .init(
            launcherURL: launcher,
            executableURL: executable,
            source: source
        )
    }

    static func defaultCandidates(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        var candidates = [
            homeDirectory.appendingPathComponent(".npm-global/bin/codex"),
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex")
            })
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

struct CodexRuntimePreferences {
    static let selectedPathKey = "miller.codex-runtime.selected-path"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPath() -> String? {
        guard let value = defaults.string(forKey: Self.selectedPathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    func save(path: String) {
        defaults.set(path, forKey: Self.selectedPathKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.selectedPathKey)
    }
}

@MainActor
final class CodexRuntimeSettingsModel: ObservableObject {
    @Published private(set) var status: String
    @Published private(set) var displayPath: String?
    @Published private(set) var requiresRelaunch = false

    private let preferences: CodexRuntimePreferences
    private let resolver: CodexRuntimeResolver

    init(
        preferences: CodexRuntimePreferences = .init(),
        resolver: CodexRuntimeResolver = .init(
            verify: { try CodexAppServerHelperVerifier().verify($0) }
        )
    ) {
        self.preferences = preferences
        self.resolver = resolver
        if let selected = resolver.resolve(savedPath: preferences.loadPath()) {
            displayPath = selected.executableURL.path
            status = selected.source == .saved ? "Selected" : "Detected"
        } else {
            displayPath = nil
            status = "Not installed"
        }
    }

    func choose(_ url: URL) throws {
        let selected = try resolver.resolveCandidate(url, source: .saved)
        preferences.save(path: selected.launcherURL.path)
        displayPath = selected.executableURL.path
        status = "Selected — relaunch Miller to apply"
        requiresRelaunch = true
    }

    func clear() {
        preferences.clear()
        if let automatic = resolver.resolve(savedPath: nil) {
            displayPath = automatic.executableURL.path
            status = "Automatic selection — relaunch Miller to apply"
        } else {
            displayPath = nil
            status = "Not installed — relaunch Miller to apply"
        }
        requiresRelaunch = true
    }

    func reportSelectionFailure() {
        status = "Unsupported Codex executable"
    }
}
