import Foundation

public struct GatewayFrameWriter: Sendable {
    private let maximumRecordBytes: Int

    public init(maximumRecordBytes: Int = GatewayProtocol.maximumRecordBytes) {
        self.maximumRecordBytes = maximumRecordBytes
    }

    public func encode(_ record: GatewayRecord) throws -> Data {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: record.object.mapValues(\.foundationValue),
                options: [.sortedKeys]
            )
        } catch {
            throw GatewayProtocolError.invalidJSON
        }
        guard data.count <= maximumRecordBytes else {
            throw GatewayProtocolError.recordTooLarge
        }
        return data + Data([0x0a])
    }
}
