import Foundation
@testable import MillerGateway
import Testing

@Suite
struct SmokeTests {
    @Test
    func moduleLoads() {
        #expect(MillerGateway.version == 1)
        #expect(GatewayProtocol.maximumRecordBytes == 1_048_576)
    }
}
