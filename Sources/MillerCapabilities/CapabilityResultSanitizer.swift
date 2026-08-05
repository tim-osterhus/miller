import Foundation
import MillerCore

public enum CapabilityResultError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidLimit
}

public struct SanitizedCapabilityResult: Equatable, Sendable {
    public let contentJSON: Data
    public let isError: Bool
    public let wasTruncated: Bool
    public let auditSummary: CapabilitySummary
}

public struct CapabilityResultSanitizer: Sendable {
    private let maximumResultBytes: Int

    public init(maximumResultBytes: Int = 256 * 1_024) {
        self.maximumResultBytes = maximumResultBytes
    }

    public func project(contentJSON: Data, isError: Bool) throws -> SanitizedCapabilityResult {
        guard maximumResultBytes >= 18, maximumResultBytes <= 256 * 1_024 else {
            throw CapabilityResultError.invalidLimit
        }
        guard (try? JSONSerialization.jsonObject(with: contentJSON)) != nil else {
            throw CapabilityResultError.invalidJSON
        }
        let wasTruncated = contentJSON.count > maximumResultBytes
        let projected = wasTruncated ? Data(#"{"truncated":true}"#.utf8) : contentJSON
        let code = isError ? "tool_result_error" : (wasTruncated ? "tool_result_truncated" : "tool_result_ok")
        return SanitizedCapabilityResult(
            contentJSON: projected,
            isError: isError,
            wasTruncated: wasTruncated,
            auditSummary: try CapabilitySummary(text: code)
        )
    }
}
