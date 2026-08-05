import Darwin
import Foundation
import Security

enum CodexAppServerHelperVerificationError: Error, Equatable, Sendable {
    case rejected
}

enum CodexAppServerHelperArchitecture: Equatable, Sendable {
    case arm64
    case x86_64
    case other
}

struct CodexAppServerHelperInspection: Equatable, Sendable {
    static let expectedIdentifier = "codex"
    static let expectedTeamIdentifier = "2DC432GLL2"

    var identifier: String
    var teamIdentifier: String
    var architecture: CodexAppServerHelperArchitecture
    var executableURL: URL
}

/// Admits an owner-installed official Codex executable before Miller hands it
/// OAuth or protocol bytes. External Codex updates may change the CDHash, so
/// admission is bound to OpenAI's Developer ID team, architecture, canonical
/// executable path, and the spawned guest rather than one build hash.
struct CodexAppServerHelperVerifier: Sendable {
    typealias Inspector = @Sendable (URL) throws -> CodexAppServerHelperInspection
    typealias RunningProcessInspector = @Sendable (pid_t) throws -> CodexAppServerHelperInspection

    private let inspect: Inspector
    private let inspectRunningProcess: RunningProcessInspector

    init(
        inspect: @escaping Inspector = Self.inspectProduction,
        inspectRunningProcess: @escaping RunningProcessInspector = Self.inspectRunningProcessProduction
    ) {
        self.inspect = inspect
        self.inspectRunningProcess = inspectRunningProcess
    }

    func verify(_ helperURL: URL) throws {
        let expectedURL = helperURL.resolvingSymlinksInPath().standardizedFileURL
        guard helperURL.isFileURL,
              helperURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: expectedURL.path),
              try isAdmitted(inspect(expectedURL), expectedExecutableURL: expectedURL)
        else { throw CodexAppServerHelperVerificationError.rejected }
    }

    func verifyRunningProcess(
        pid: pid_t,
        expectedExecutableURL: URL
    ) throws {
        guard pid > 0 else { throw CodexAppServerHelperVerificationError.rejected }
        let expectedURL = expectedExecutableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard try isAdmitted(
            inspectRunningProcess(pid),
            expectedExecutableURL: expectedURL
        ) else { throw CodexAppServerHelperVerificationError.rejected }
    }

    /// Retained only for injected tests while production captures and passes
    /// the selected executable URL through `GPTLiveController`.
    func verifyRunningProcess(pid: pid_t) throws {
        guard pid > 0 else { throw CodexAppServerHelperVerificationError.rejected }
        let inspection = try inspectRunningProcess(pid)
        guard try isAdmitted(
            inspection,
            expectedExecutableURL: inspection.executableURL
        ) else { throw CodexAppServerHelperVerificationError.rejected }
    }

    private func isAdmitted(
        _ inspection: CodexAppServerHelperInspection,
        expectedExecutableURL: URL
    ) throws -> Bool {
        inspection.identifier == CodexAppServerHelperInspection.expectedIdentifier
            && inspection.teamIdentifier == CodexAppServerHelperInspection.expectedTeamIdentifier
            && inspection.architecture == .arm64
            && inspection.executableURL.resolvingSymlinksInPath().standardizedFileURL
                == expectedExecutableURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static let executionRequirement =
        "identifier \"codex\" and anchor apple generic "
        + "and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ "
        + "and certificate leaf[subject.OU] = \"2DC432GLL2\""

    private static func inspectProduction(
        _ helperURL: URL
    ) throws -> CodexAppServerHelperInspection {
        let canonicalURL = helperURL.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonicalURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw CodexAppServerHelperVerificationError.rejected
        }
        let architecture = try executableArchitecture(at: canonicalURL)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(canonicalURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { throw CodexAppServerHelperVerificationError.rejected }
        try validate(staticCode)
        let identity = try signingIdentity(for: staticCode)
        return .init(
            identifier: identity.identifier,
            teamIdentifier: identity.teamIdentifier,
            architecture: architecture,
            executableURL: canonicalURL
        )
    }

    private static func inspectRunningProcessProduction(
        _ pid: pid_t
    ) throws -> CodexAppServerHelperInspection {
        guard pid > 0 else { throw CodexAppServerHelperVerificationError.rejected }
        let admittedCode = try runningCode(for: pid)
        let requirement = try expectedExecutionRequirement()
        guard SecCodeCheckValidity(admittedCode, validationFlags, requirement) == errSecSuccess
        else { throw CodexAppServerHelperVerificationError.rejected }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(admittedCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else { throw CodexAppServerHelperVerificationError.rejected }
        try validate(staticCode)
        let executableURL = try executableURL(for: staticCode)
        let identity = try signingIdentity(for: staticCode)
        return .init(
            identifier: identity.identifier,
            teamIdentifier: identity.teamIdentifier,
            architecture: try executableArchitecture(at: executableURL),
            executableURL: executableURL
        )
    }

    private static func validate(_ staticCode: SecStaticCode) throws {
        let requirement = try expectedExecutionRequirement()
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess
        else { throw CodexAppServerHelperVerificationError.rejected }
    }

    private static func expectedExecutionRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            executionRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement
        else { throw CodexAppServerHelperVerificationError.rejected }
        return requirement
    }

    private static let validationFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | (1 << 29)
    )

    private static func signingIdentity(
        for code: SecStaticCode
    ) throws -> (identifier: String, teamIdentifier: String) {
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
        let signingInfo = signingInfo as? [String: Any],
        let identifier = signingInfo[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
        else { throw CodexAppServerHelperVerificationError.rejected }
        return (identifier, teamIdentifier)
    }

    private static func runningCode(for pid: pid_t) throws -> SecCode {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid),
        ] as CFDictionary
        for attempt in 0..<25 {
            var runningCode: SecCode?
            let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode)
            if status == errSecSuccess, let runningCode { return runningCode }
            guard status == errSecCSNoSuchCode, attempt < 24 else {
                throw CodexAppServerHelperVerificationError.rejected
            }
            usleep(10_000)
        }
        throw CodexAppServerHelperVerificationError.rejected
    }

    private static func executableURL(for staticCode: SecStaticCode) throws -> URL {
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess,
              let path
        else { throw CodexAppServerHelperVerificationError.rejected }
        return (path as URL)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func executableArchitecture(
        at helperURL: URL
    ) throws -> CodexAppServerHelperArchitecture {
        let handle = try FileHandle(forReadingFrom: helperURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8_192) ?? Data()
        guard data.count >= 8 else { throw CodexAppServerHelperVerificationError.rejected }
        let magic = readUInt32(data, offset: 0, bigEndian: true)
        switch magic {
        case 0xFEEDFACE, 0xFEEDFACF:
            return architecture(
                cpuType: readUInt32(data, offset: 4, bigEndian: true),
                cpuSubtype: readUInt32(data, offset: 8, bigEndian: true)
            )
        case 0xCEFAEDFE, 0xCFFAEDFE:
            return architecture(
                cpuType: readUInt32(data, offset: 4, bigEndian: false),
                cpuSubtype: readUInt32(data, offset: 8, bigEndian: false)
            )
        default:
            throw CodexAppServerHelperVerificationError.rejected
        }
    }

    private static func architecture(
        cpuType: UInt32,
        cpuSubtype: UInt32
    ) -> CodexAppServerHelperArchitecture {
        guard cpuType == 0x0100_000C else {
            return cpuType == 0x0100_0007 ? .x86_64 : .other
        }
        return (cpuSubtype & 0x00FF_FFFF) == 0 ? .arm64 : .other
    }

    private static func readUInt32(
        _ data: Data,
        offset: Int,
        bigEndian: Bool
    ) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        return bigEndian ? value : value.byteSwapped
    }
}
