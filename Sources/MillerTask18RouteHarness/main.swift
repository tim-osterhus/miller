import Darwin
import Foundation
import MillerCapabilities
import MillerCore

private let maximumPathBytes = 4_096
private let maximumAuditBytes = 64 * 1_024

private enum RouteHarnessError: Error {
    case invalidEnvironment
    case unsafePath
    case unsafeRoot
    case unsafeTrustedParent
    case unsafeNode
    case unsafeFixture
    case unsafeAudit
    case unsafeReady
    case unsafeOutput
    case invalidCatalog
}

private struct Configuration {
    let root: URL
    let node: URL
    let fixture: URL
    let audit: URL
    let fixtureAudit: URL
    let ready: URL
    let trustedParent: URL
    let route: String
    let profileID: UUID
}

private actor AuditWriter {
    private let handle: FileHandle
    private var bytes = 0

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RouteHarnessError.unsafeOutput
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw RouteHarnessError.unsafeOutput }
        guard chmod(url.path, 0o600) == 0 else {
            throw RouteHarnessError.unsafeOutput
        }
        self.handle = try FileHandle(forWritingTo: url)
    }

    func append(_ record: [String: String]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        ) else { return }
        let frame = data + Data([0x0a])
        guard bytes + frame.count <= maximumAuditBytes else { return }
        handle.seekToEndOfFile()
        handle.write(frame)
        bytes += frame.count
    }

    func close() {
        try? handle.synchronize()
        try? handle.close()
    }
}

@main
struct MillerTask18RouteHarness {
    static func main() async {
        do {
            try await run()
        } catch {
            let code = failureCode(error)
            FileHandle.standardError.write(
                Data("task18_broker_harness_failed_\(code)\n".utf8)
            )
            exit(1)
        }
    }

    private static func failureCode(_ error: Error) -> String {
        switch error {
        case RouteHarnessError.invalidEnvironment: return "invalid_environment"
        case RouteHarnessError.unsafePath: return "unsafe_path"
        case RouteHarnessError.unsafeRoot: return "unsafe_root"
        case RouteHarnessError.unsafeTrustedParent: return "unsafe_trusted_parent"
        case RouteHarnessError.unsafeNode: return "unsafe_node"
        case RouteHarnessError.unsafeFixture: return "unsafe_fixture"
        case RouteHarnessError.unsafeAudit: return "unsafe_audit"
        case RouteHarnessError.unsafeReady: return "unsafe_ready"
        case RouteHarnessError.unsafeOutput: return "unsafe_output"
        case RouteHarnessError.invalidCatalog: return "invalid_catalog"
        case is CapabilityRPCError: return "rpc"
        case is CapabilityBrokerError: return "broker"
        case is MCPConfigurationError: return "mcp_configuration"
        case is MCPClientSessionError: return "mcp_session"
        default: return "unknown"
        }
    }

    private static func run() async throws {
        let configuration = try Configuration(environment: ProcessInfo.processInfo.environment)
        do { try ensurePrivateDirectory(configuration.root) }
        catch { throw RouteHarnessError.unsafeRoot }
        do { try ensurePrivateDirectory(configuration.trustedParent) }
        catch { throw RouteHarnessError.unsafeTrustedParent }
        do { try validateRegularExecutable(configuration.node) }
        catch { throw RouteHarnessError.unsafeNode }
        do { try validateRegularFile(configuration.fixture) }
        catch { throw RouteHarnessError.unsafeFixture }
        do { try validateNewOutput(configuration.audit) }
        catch { throw RouteHarnessError.unsafeAudit }
        do { try validateNewOutput(configuration.fixtureAudit) }
        catch { throw RouteHarnessError.unsafeAudit }
        do { try validateNewOutput(configuration.ready) }
        catch { throw RouteHarnessError.unsafeReady }

        let audit = try AuditWriter(url: configuration.audit)
        let mcp = try MCPServerConfiguration(
            id: "task18_fixture",
            displayName: "Task 18 local read-only fixture",
            transport: .stdio(
                executable: configuration.node.path,
                arguments: [
                    configuration.fixture.path,
                    "--root", configuration.root.path,
                    "--audit", configuration.fixtureAudit.path,
                    "--route", configuration.route,
                ]
            ),
            enabled: true,
            defaultPolicy: .readOnlyAutomatic,
            providerProfileIDs: [configuration.profileID],
            bounds: MCPBounds(
                startupTimeout: .seconds(10),
                callTimeout: .seconds(10)
            )
        )
        let broker = try CapabilityBroker(
            configurations: [mcp],
            approval: { _ in .allowOnce },
            audit: { event in
                await audit.append([
                    "source": "miller_capability_broker",
                    "route": configuration.route,
                    "phase": event.state.rawValue,
                    "capability_id": event.capabilityID.rawValue,
                    "summary": event.summary.text,
                    "outcome": event.outcome?.rawValue ?? "none",
                    "policy": event.policy.value.rawValue,
                ])
            }
        )
        _ = await broker.refresh()

        let server = CapabilityRPCServer(
            trustedParent: configuration.trustedParent,
            handler: { request in
                await handle(
                    request,
                    broker: broker,
                    audit: audit,
                    route: configuration.route,
                    profileID: configuration.profileID
                )
            }
        )
        let endpoint = try await server.start()
        let ready: [String: String] = [
            "socket": endpoint.socketURL.path,
            "token": endpoint.token.environmentValue,
            "trusted_parent": endpoint.trustedParentURL.path,
            "provider_profile_id": configuration.profileID.uuidString,
        ]
        try writeReady(ready, to: configuration.ready)
        FileHandle.standardOutput.write(Data("MILLER_TASK18_BROKER_HARNESS_READY=1\n".utf8))
        _ = FileHandle.standardInput.readDataToEndOfFile()
        await server.stop()
        await broker.disconnectAll()
        await audit.close()
    }

    private static func handle(
        _ request: CapabilityRPCRequest,
        broker: CapabilityBroker,
        audit: AuditWriter,
        route: String,
        profileID: UUID
    ) async -> CapabilityRPCResponse {
        switch request {
        case .list(let requestedProfileID):
            guard requestedProfileID == profileID else {
                return .catalog([])
            }
            return .catalog(await broker.catalog(providerProfileID: profileID))
        case .call(let callID, let capabilityID, let argumentsJSON):
            do {
                let result = try await broker.call(
                    callID: callID,
                    capabilityID: capabilityID,
                    argumentsJSON: argumentsJSON,
                    providerProfileID: profileID
                )
                await audit.append([
                    "source": "miller_capability_broker",
                    "route": route,
                    "phase": "result",
                    "capability_id": capabilityID.rawValue,
                    "summary": result.auditSummary.text,
                    "outcome": result.isError ? "failed" : "succeeded",
                ])
                return .result(
                    callID,
                    contentJSON: result.contentJSON,
                    isError: result.isError
                )
            } catch let error as CapabilityBrokerError {
                let code: String
                switch error {
                case .declined: code = "declined"
                case .timedOut: code = "timed_out"
                case .capabilityUnavailable: code = "unavailable"
                default: code = "failed"
                }
                await audit.append([
                    "source": "miller_capability_broker",
                    "route": route,
                    "phase": "result",
                    "capability_id": capabilityID.rawValue,
                    "summary": "tool_result_error",
                    "outcome": code,
                ])
                return .failed(callID, code: code)
            } catch {
                await audit.append([
                    "source": "miller_capability_broker",
                    "route": route,
                    "phase": "result",
                    "capability_id": capabilityID.rawValue,
                    "summary": "tool_result_error",
                    "outcome": "failed",
                ])
                return .failed(callID, code: "failed")
            }
        case .cancel(let callID):
            return .failed(callID, code: "cancelled")
        }
    }

    private static func writeReady(
        _ values: [String: String],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".task18-ready-\(UUID().uuidString)")
        try writeExclusive(data, to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw RouteHarnessError.unsafeOutput
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw RouteHarnessError.unsafeOutput }
        do {
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        data.count - offset
                    )
                }
                guard count > 0 else { throw RouteHarnessError.unsafeOutput }
                offset += count
            }
            guard fsync(descriptor) == 0, close(descriptor) == 0 else {
                throw RouteHarnessError.unsafeOutput
            }
        } catch {
            close(descriptor)
            unlink(url.path)
            throw error
        }
    }
}

private extension Configuration {
    init(environment: [String: String]) throws {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty,
                  value.utf8.count <= maximumPathBytes,
                  value.hasPrefix("/"), !value.contains("\0")
            else { throw RouteHarnessError.invalidEnvironment }
            return value
        }
        guard let route = environment["MILLER_TASK18_ROUTE"],
              ["typed", "sideband", "pi"].contains(route),
              let profileValue = environment["MILLER_TASK18_PROVIDER_PROFILE_ID"],
              let profileID = UUID(uuidString: profileValue)
        else { throw RouteHarnessError.invalidEnvironment }
        self.root = URL(filePath: try required("MILLER_TASK18_FIXTURE_ROOT"))
        self.node = URL(filePath: try required("MILLER_TASK18_NODE_PATH"))
        self.fixture = URL(filePath: try required("MILLER_TASK18_MCP_FIXTURE"))
        self.audit = URL(filePath: try required("MILLER_TASK18_BROKER_AUDIT_PATH"))
        self.fixtureAudit = URL(filePath: try required("MILLER_TASK18_FIXTURE_AUDIT_PATH"))
        self.ready = URL(filePath: try required("MILLER_TASK18_READY_PATH"))
        self.trustedParent = URL(filePath: try required("MILLER_TASK18_TRUSTED_PARENT"))
        self.route = route
        self.profileID = profileID
    }
}

private func ensurePrivateDirectory(_ url: URL) throws {
    var value = stat()
    if lstat(url.path, &value) == 0 {
        guard (value.st_mode & S_IFMT) == S_IFDIR,
              (value.st_mode & 0o777) == 0o700,
              value.st_uid == geteuid()
        else { throw RouteHarnessError.unsafePath }
        return
    }
    guard errno == ENOENT else { throw RouteHarnessError.unsafePath }
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    guard lstat(url.path, &value) == 0,
          (value.st_mode & S_IFMT) == S_IFDIR,
          (value.st_mode & 0o777) == 0o700,
          value.st_uid == geteuid()
    else { throw RouteHarnessError.unsafePath }
}

private func validateRegularExecutable(_ url: URL) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0,
          (value.st_mode & S_IFMT) == S_IFREG,
          value.st_uid == geteuid(),
          access(url.path, X_OK) == 0
    else { throw RouteHarnessError.unsafePath }
}

private func validateRegularFile(_ url: URL) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0,
          (value.st_mode & S_IFMT) == S_IFREG,
          value.st_uid == geteuid()
    else { throw RouteHarnessError.unsafePath }
}

private func validateNewOutput(_ url: URL) throws {
    var value = stat()
    guard lstat(url.path, &value) != 0, errno == ENOENT else {
        throw RouteHarnessError.unsafeOutput
    }
}
