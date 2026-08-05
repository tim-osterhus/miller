import Foundation

public struct GatewayFrameReader: Sendable {
    private var pending = Data()
    private let maximumRecordBytes: Int

    public init(maximumRecordBytes: Int = GatewayProtocol.maximumRecordBytes) {
        self.maximumRecordBytes = maximumRecordBytes
    }

    public mutating func consume(_ data: Data) throws -> [GatewayRecord] {
        var records: [GatewayRecord] = []
        var start = data.startIndex
        while start < data.endIndex {
            if let newline = data[start...].firstIndex(of: 0x0a) {
                try append(data[start..<newline])
                guard !pending.isEmpty else {
                    throw GatewayProtocolError.invalidFraming
                }
                records.append(try GatewayRecord.decode(pending))
                pending.removeAll(keepingCapacity: true)
                start = data.index(after: newline)
            } else {
                try append(data[start...])
                break
            }
        }
        return records
    }

    public mutating func finish() throws {
        guard pending.isEmpty else {
            throw GatewayProtocolError.incompleteRecord
        }
    }

    private mutating func append<S: Sequence>(_ bytes: S) throws
    where S.Element == UInt8 {
        for byte in bytes {
            guard byte != 0x00, byte != 0x0d else {
                throw GatewayProtocolError.invalidFraming
            }
            guard pending.count < maximumRecordBytes else {
                throw GatewayProtocolError.recordTooLarge
            }
            pending.append(byte)
        }
    }
}
