import Foundation
@testable import MillerCapabilities
import Testing

@Suite
struct CapabilityResultSanitizerTests {
    @Test
    func boundsToolResultsWithoutLeakingContentIntoAudit() throws {
        let sanitizer = CapabilityResultSanitizer(maximumResultBytes: 32)
        let projected = try sanitizer.project(
            contentJSON: Data(#"{"text":"abcdefghijklmnopqrstuvwxyz"}"#.utf8),
            isError: false
        )
        #expect(projected.contentJSON.count <= 32)
        #expect(projected.wasTruncated)
        #expect(projected.auditSummary.text == "tool_result_truncated")
        #expect(!projected.auditSummary.text.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    @Test
    func rejectsInvalidJSONAndUsesClosedAuditCodes() throws {
        let sanitizer = CapabilityResultSanitizer()
        #expect(throws: CapabilityResultError.invalidJSON) {
            try sanitizer.project(contentJSON: Data("secret token".utf8), isError: false)
        }
        let projected = try sanitizer.project(
            contentJSON: Data(#"{"ok":false}"#.utf8), isError: true
        )
        #expect(projected.auditSummary.text == "tool_result_error")
    }
}
