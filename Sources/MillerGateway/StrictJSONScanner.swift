import Foundation

enum StrictJSONScanner {
    static func validate(_ data: Data) throws {
        guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else {
            throw GatewayProtocolError.invalidUTF8
        }
        var parser = Parser(bytes: Array(string.utf8))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            guard index == bytes.count else {
                throw GatewayProtocolError.invalidJSON
            }
        }

        private mutating func parseValue() throws {
            guard index < bytes.count else {
                throw GatewayProtocolError.invalidJSON
            }
            switch bytes[index] {
            case 0x7b: try parseObject()
            case 0x5b: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try consumeLiteral("true")
            case 0x66: try consumeLiteral("false")
            case 0x6e: try consumeLiteral("null")
            case 0x2d, 0x30 ... 0x39: try parseNumber()
            default: throw GatewayProtocolError.invalidJSON
            }
        }

        private mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            if consume(0x7d) { return }
            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw GatewayProtocolError.invalidJSON
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw GatewayProtocolError.duplicateKey
                }
                skipWhitespace()
                guard consume(0x3a) else {
                    throw GatewayProtocolError.invalidJSON
                }
                skipWhitespace()
                try parseValue()
                skipWhitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else {
                    throw GatewayProtocolError.invalidJSON
                }
                skipWhitespace()
            }
        }

        private mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5d) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else {
                    throw GatewayProtocolError.invalidJSON
                }
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    let encoded = Data(bytes[start..<index])
                    guard let decoded = try? JSONSerialization.jsonObject(
                        with: Data([0x5b]) + encoded + Data([0x5d])
                    ) as? [String],
                        let value = decoded.first
                    else {
                        throw GatewayProtocolError.invalidJSON
                    }
                    return value
                }
                if byte < 0x20 {
                    throw GatewayProtocolError.invalidJSON
                }
                if byte == 0x5c {
                    index += 1
                    guard index < bytes.count else {
                        throw GatewayProtocolError.invalidJSON
                    }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy(isHex)
                        else {
                            throw GatewayProtocolError.invalidJSON
                        }
                        index += 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74]
                        .contains(bytes[index])
                    {
                        throw GatewayProtocolError.invalidJSON
                    }
                }
                index += 1
            }
            throw GatewayProtocolError.invalidJSON
        }

        private mutating func parseNumber() throws {
            let start = index
            if consume(0x2d), index == bytes.count {
                throw GatewayProtocolError.invalidJSON
            }
            if consume(0x30) {
                if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    throw GatewayProtocolError.invalidJSON
                }
            } else {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                    throw GatewayProtocolError.invalidJSON
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            if consume(0x2e) {
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw GatewayProtocolError.invalidJSON
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d {
                    index += 1
                }
                guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                    throw GatewayProtocolError.invalidJSON
                }
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                    index += 1
                }
            }
            guard index > start else { throw GatewayProtocolError.invalidJSON }
        }

        private mutating func consumeLiteral(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected
            else {
                throw GatewayProtocolError.invalidJSON
            }
            index += expected.count
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte)
                || (0x41...0x46).contains(byte)
                || (0x61...0x66).contains(byte)
        }
    }
}
