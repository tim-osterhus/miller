import Foundation
import SwiftUI

struct DiagnosticsSettingsRow: Equatable, Sendable {
    let label: String
    let value: String
}

struct DiagnosticsSettingsSnapshot: Equatable, Sendable {
    let componentVersions: [String: String]
    let sanitizedLastFailure: String?
    let catalogFreshness: String
    let brokerProcessState: String
    let adapterProcessState: String
    var controllerState = "Unavailable"
    var bridgeRPCState = "Unavailable"
    var mcpChildState = "Unavailable"
    let managedDataBytes: Int64
    let managedCacheBytes: Int64
    var managedDataLabel: String? = nil
    var managedCacheLabel: String? = nil

    var rows: [DiagnosticsSettingsRow] {
        let versionRows = componentVersions.keys.sorted().map {
            DiagnosticsSettingsRow(label: "\($0) version", value: componentVersions[$0]!)
        }
        return versionRows + [
            .init(label: "Last failure", value: sanitizedLastFailure ?? "None"),
            .init(label: "Catalog", value: catalogFreshness),
            .init(label: "Capability controller", value: controllerState),
            .init(label: "Broker process", value: brokerProcessState),
            .init(label: "Bridge RPC", value: bridgeRPCState),
            .init(label: "Adapter process", value: adapterProcessState),
            .init(label: "MCP child sessions", value: mcpChildState),
            .init(
                label: "Managed data",
                value: managedDataLabel ?? "\(managedDataBytes) bytes"
            ),
            .init(
                label: "Managed cache",
                value: managedCacheLabel ?? "\(managedCacheBytes) bytes"
            ),
        ]
    }

    static let unavailable = Self(
        componentVersions: ["Miller": "Unknown"],
        sanitizedLastFailure: nil,
        catalogFreshness: "Unavailable",
        brokerProcessState: "Unavailable",
        adapterProcessState: "Unavailable",
        managedDataBytes: 0,
        managedCacheBytes: 0,
        managedDataLabel: "Unavailable",
        managedCacheLabel: "Unavailable"
    )
}

struct DiagnosticsSettingsDependencies: Sendable {
    let load: @Sendable () async -> DiagnosticsSettingsSnapshot
    static let unavailable = Self(load: { .unavailable })
}

@MainActor
final class DiagnosticsSettingsModel: ObservableObject {
    @Published private(set) var snapshot = DiagnosticsSettingsSnapshot.unavailable
    private let dependencies: DiagnosticsSettingsDependencies

    init(dependencies: DiagnosticsSettingsDependencies = .unavailable) {
        self.dependencies = dependencies
    }

    func load() async { snapshot = await dependencies.load() }
}

struct DiagnosticsSettingsTab: View {
    let section = SettingsSection.diagnostics
    @ObservedObject var model: AppPresentationModel
    @ObservedObject var diagnostics: DiagnosticsSettingsModel
    @State private var keychainResult: String?

    init(
        model: AppPresentationModel,
        diagnostics: DiagnosticsSettingsModel = .init()
    ) {
        self.model = model
        self.diagnostics = diagnostics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.contentSpacing) {
                GroupBox("Components and processes") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(diagnostics.snapshot.rows.enumerated()), id: \.offset) {
                            _, row in
                            LabeledContent(row.label) { Text(row.value) }
                        }
                        LabeledContent("Typed conversation") { Text("Ready") }
                        LabeledContent("Live voice") { Text(model.voiceStatusText) }
                        LabeledContent("Avatar") { Text("Unavailable") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Keychain qualification") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Run Keychain probe") {
                            do {
                                try KeychainProbe().run()
                                keychainResult = "Probe succeeded and cleaned up"
                            } catch {
                                keychainResult = "Probe failed"
                            }
                        }
                        if let keychainResult { Text(keychainResult) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .accessibilityLabel(section.accessibilityLabel)
        .task { await diagnostics.load() }
    }
}
