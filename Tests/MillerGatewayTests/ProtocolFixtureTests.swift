import Foundation
@testable import MillerGateway
import Testing

@Suite
struct ProtocolFixtureTests {
    private let session = "00000000-0000-4000-8000-000000000001"
    private let request = "00000000-0000-4000-8000-000000000002"
    private let turn = "00000000-0000-4000-8000-000000000003"

    @Test
    func legalFixturesDecodeExactlyOneRecordAndCoverTheSchema() throws {
        let root = fixtureRoot.appendingPathComponent("legal")
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)

        var fixtureTypes: Set<String> = []
        for file in files {
            var reader = GatewayFrameReader()
            let records = try reader.consume(Data(contentsOf: file))
            try reader.finish()
            #expect(records.count == 1, Comment(rawValue: file.lastPathComponent))
            fixtureTypes.insert(try #require(records.first).type)
        }
        let schemaTypes = try schemaRecordTypes()
        #expect(fixtureTypes == schemaTypes)
    }

    @Test
    func hostileCorpusIsCompleteAndRejected() throws {
        let corpus = try hostileCorpus()
        let root = fixtureRoot.appendingPathComponent("invalid")
        let expectedFiles = Set(corpus.invalid.compactMap(\.file)).union(["manifest.json"])
        let actualFiles = Set(try FileManager.default.contentsOfDirectory(
            atPath: root.path
        ))
        #expect(actualFiles == expectedFiles)

        for hostile in corpus.invalid {
            switch hostile.kind {
            case "file", "template":
                let data = try Data(contentsOf: root.appendingPathComponent(
                    try #require(hostile.file)
                ))
                let resolved = hostile.kind == "template"
                    ? Data(String(decoding: data, as: UTF8.self).replacing(
                        "__SESSION_ID__", with: session
                    ).utf8)
                    : data
                var reader = GatewayFrameReader()
                if hostile.phase == "finish" {
                    _ = try reader.consume(resolved)
                    expectThrows(hostile.id) { try reader.finish() }
                } else {
                    expectThrows(hostile.id) { _ = try reader.consume(resolved) }
                }
            case "bytes":
                var reader = GatewayFrameReader()
                let data = Data(hex: try #require(hostile.hex))
                if hostile.phase == "finish" {
                    _ = try reader.consume(data)
                    expectThrows(hostile.id) { try reader.finish() }
                } else {
                    expectThrows(hostile.id) { _ = try reader.consume(data) }
                }
            case "repeat":
                var reader = GatewayFrameReader()
                let byte = try #require(hostile.byte)
                let count = try #require(hostile.count)
                expectThrows(hostile.id) {
                    _ = try reader.consume(Data(repeating: byte, count: count))
                }
            case "sequence":
                let data = try Data(contentsOf: root.appendingPathComponent(
                    try #require(hostile.file)
                ))
                var reader = GatewayFrameReader()
                let records = try reader.consume(data)
                try reader.finish()
                expectThrows(hostile.id) { try assertRejectedSequence(records) }
            default:
                Issue.record("Unimplemented hostile corpus kind: \(hostile.kind)")
            }
        }
    }

    @Test
    func readinessStatusValuesMatchTheFrozenSchema() throws {
        for status in try schemaReadinessStatuses() {
            _ = try readinessResult(status: status)
        }
        expectThrows("unknown readiness status") {
            _ = try readinessResult(status: "invented")
        }
    }

    @Test
    func schemaConstraintParityCoversEveryLegalRecord() throws {
        let definitions = try schemaDefinitions()
        let fixtures = try legalFixtureObjects()
        let fixtureTypes = Set(try fixtures.map { try recordType($0.object) })
        let schemaTypes = try schemaRecordTypes()
        #expect(fixtureTypes == schemaTypes)
        var inventory: Set<String> = []
        var exercised: Set<String> = []

        for fixture in fixtures {
            let type = try recordType(fixture.object)
            let recordSchema = try resolvedSchema(
                try #require(definitions[type]),
                definitions: definitions
            )
            try collectConstraintInventory(
                recordSchema,
                recordType: type,
                path: "$record",
                definitions: definitions,
                into: &inventory
            )
            let properties = try schemaProperties(recordSchema)
            let required = Set(try schemaRequired(recordSchema))
            guard required.isSubset(of: Set(properties.keys)) else {
                throw GatewayProtocolError.invalidJSON
            }
            exercised.insert(occurrence(type, "$record", "type"))
            exercised.insert(occurrence(type, "$record", "properties"))
            exercised.insert(occurrence(type, "$record", "required"))

            for field in required {
                var missing = fixture.object
                missing.removeValue(forKey: field)
                expectDecodeFailure("\(type) requires \(field)", object: missing)
            }

            var unknown = fixture.object
            unknown["unclassified_protocol_field"] = "fixture"
            expectDecodeFailure("\(type) rejects unknown fields", object: unknown)
            if recordSchema["additionalProperties"] != nil {
                exercised.insert(occurrence(type, "$record", "additionalProperties"))
            }
            if recordSchema["unevaluatedProperties"] != nil {
                exercised.insert(occurrence(type, "$record", "unevaluatedProperties"))
            }

            for (field, rawConstraint) in properties {
                let constraint = try resolvedSchema(rawConstraint, definitions: definitions)
                try assertFieldParity(
                    field: field,
                    constraint: constraint,
                    fixture: fixture.object,
                    recordType: type,
                    definitions: definitions,
                    exercised: &exercised
                )
                if !required.contains(field) {
                    try assertOptionalParity(
                        field: field,
                        constraint: constraint,
                        fixture: fixture.object
                    )
                }
            }
        }
        #expect(exercised == inventory)
        let missing = inventory.subtracting(exercised).sorted()
        let unexpected = exercised.subtracting(inventory).sorted()
        #expect(missing.isEmpty, Comment(rawValue: "Unexercised constraints: \(missing)"))
        #expect(unexpected.isEmpty, Comment(rawValue: "Unexpected probes: \(unexpected)"))
        let schemaEnumPaths = Set(inventory.compactMap { entry -> String? in
            guard entry.hasSuffix("/enum") else { return nil }
            return String(entry.dropLast("/enum".count))
        })
        #expect(schemaEnumPaths == Set(GatewayRecord.enumAuthority.keys))
        print(
            "Protocol parity matrix covers \(fixtures.count) records and "
                + "\(exercised.count) normalized constraint occurrences"
        )
    }

    @Test
    func writerRefusesOversizedEncodedRecord() throws {
        let record = try GatewayRecord.make(
            type: "reasoning.text_delta",
            sessionID: session,
            requestID: request,
            fields: [
                "turn_id": .string(turn),
                "generation": .integer(1),
                "ordinal": .integer(0),
                "text": .string(String(repeating: "x", count: 256)),
            ]
        )
        let writer = GatewayFrameWriter(maximumRecordBytes: 128)
        expectThrows("oversized encoded record") {
            _ = try writer.encode(record)
        }
    }

    @Test
    func modelCatalogRecordsAreClosedAndRequireWellFormedChoices() throws {
        let requestRecord = try GatewayRecord.make(
            type: "provider.models",
            sessionID: session,
            requestID: request,
            fields: ["provider_kind": .string("codex_oauth")]
        )
        #expect(requestRecord["provider_kind"]?.stringValue == "codex_oauth")

        let resultFields: [String: JSONValue] = [
            "provider_kind": .string("codex_oauth"),
            "default_model": .string("gpt-5.6-terra"),
            "models": .array([
                .object([
                    "id": .string("gpt-5.6-terra"),
                    "name": .string("GPT-5.6 Terra"),
                ]),
                .object([
                    "id": .string("gpt-5.4"),
                    "name": .string("GPT-5.4"),
                ]),
            ]),
        ]
        let result = try GatewayRecord.make(
            type: "provider.models_result",
            sessionID: session,
            requestID: request,
            fields: resultFields
        )
        #expect(result["default_model"]?.stringValue == "gpt-5.6-terra")

        var unknown = result.object.mapValues(\.foundationValue)
        unknown["models"] = [[
            "id": "gpt-5.6-terra",
            "name": "GPT-5.6 Terra",
            "extra": "nope",
        ]]
        expectDecodeFailure("model choice rejects unknown fields", object: unknown)

        var malformed = result.object.mapValues(\.foundationValue)
        malformed["models"] = [["id": "gpt-5.6-terra"]]
        expectDecodeFailure("model choice requires name", object: malformed)
    }

    private func assertRejectedSequence(_ records: [GatewayRecord]) throws {
        var validator = GatewaySessionValidator()
        for record in records {
            switch record.type {
            case "reasoning.start":
                guard let requestID = record.requestID,
                      let turnID = record["turn_id"]?.stringValue,
                      let generation = record["generation"]?.integerValue
                else {
                    throw GatewayProtocolError.invalidJSON
                }
                try validator.register(
                    requestID: requestID,
                    turnID: turnID,
                    generation: generation
                )
            default:
                try validator.accept(record)
            }
        }
        throw GatewayProtocolError.invalidSequence
    }

    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Gateway/protocol/v1")
    }

    private func hostileCorpus() throws -> HostileCorpus {
        let url = fixtureRoot
            .appendingPathComponent("invalid")
            .appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(HostileCorpus.self, from: Data(contentsOf: url))
    }

    private func schemaRecordTypes() throws -> Set<String> {
        let schema = try schema()
        guard let entries = schema["oneOf"] as? [[String: String]] else {
            throw GatewayProtocolError.invalidJSON
        }
        return Set(try entries.map { entry in
            guard let reference = entry["$ref"] else {
                throw GatewayProtocolError.invalidJSON
            }
            guard let type = reference.split(separator: "/").last else {
                throw GatewayProtocolError.invalidJSON
            }
            return String(type)
        })
    }

    private func schemaReadinessStatuses() throws -> [String] {
        let schema = try schema()
        guard let definitions = schema["$defs"] as? [String: Any],
              let readiness = definitions["provider.readiness_result"] as? [String: Any],
              let allOf = readiness["allOf"] as? [[String: Any]],
              let fields = allOf.last?["properties"] as? [String: Any],
              let status = fields["status"] as? [String: Any],
              let values = status["enum"] as? [String]
        else {
            throw GatewayProtocolError.invalidJSON
        }
        return values
    }

    private func schema() throws -> [String: Any] {
        let url = fixtureRoot.appendingPathComponent("records.schema.json")
        guard let schema = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any] else {
            throw GatewayProtocolError.invalidJSON
        }
        return schema
    }

    private func legalFixtureObjects() throws -> [(name: String, object: [String: Any])] {
        let root = fixtureRoot.appendingPathComponent("legal")
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                guard let object = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: file)
                ) as? [String: Any] else {
                    throw GatewayProtocolError.invalidJSON
                }
                return (file.lastPathComponent, object)
            }
    }

    private func schemaDefinitions() throws -> [String: [String: Any]] {
        guard let definitions = try schema()["$defs"] as? [String: [String: Any]] else {
            throw GatewayProtocolError.invalidJSON
        }
        return definitions
    }

    private func resolvedSchema(
        _ schema: [String: Any],
        definitions: [String: [String: Any]]
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        if let reference = schema["$ref"] as? String {
            guard let name = reference.split(separator: "/").last,
                  let referenced = definitions[String(name)]
            else {
                throw GatewayProtocolError.invalidJSON
            }
            result = try resolvedSchema(referenced, definitions: definitions)
        }
        if let allOf = schema["allOf"] as? [[String: Any]] {
            for component in allOf {
                result = try mergeSchemas(
                    result,
                    resolvedSchema(component, definitions: definitions)
                )
            }
        }
        var direct = schema
        direct.removeValue(forKey: "$ref")
        direct.removeValue(forKey: "allOf")
        return try mergeSchemas(result, direct)
    }

    private func mergeSchemas(
        _ left: [String: Any],
        _ right: [String: Any]
    ) throws -> [String: Any] {
        var result = left
        for (key, value) in right {
            switch key {
            case "required":
                let existing = result[key] as? [String] ?? []
                let additions = value as? [String] ?? []
                result[key] = Array(Set(existing).union(additions)).sorted()
            case "properties":
                var properties = result[key] as? [String: Any] ?? [:]
                guard let additions = value as? [String: Any] else {
                    throw GatewayProtocolError.invalidJSON
                }
                for (field, constraint) in additions {
                    if let existing = properties[field] as? [String: Any],
                       let additional = constraint as? [String: Any]
                    {
                        properties[field] = try mergeSchemas(existing, additional)
                    } else {
                        properties[field] = constraint
                    }
                }
                result[key] = properties
            default:
                result[key] = value
            }
        }
        return result
    }

    private func schemaProperties(_ schema: [String: Any]) throws -> [String: [String: Any]] {
        guard let properties = schema["properties"] as? [String: [String: Any]] else {
            throw GatewayProtocolError.invalidJSON
        }
        return properties
    }

    private func schemaRequired(_ schema: [String: Any]) throws -> [String] {
        guard let required = schema["required"] as? [String] else {
            throw GatewayProtocolError.invalidJSON
        }
        return required
    }

    private func recordType(_ object: [String: Any]) throws -> String {
        guard let type = object["type"] as? String else {
            throw GatewayProtocolError.invalidJSON
        }
        return type
    }

    private func collectConstraintInventory(
        _ constraint: [String: Any],
        recordType: String,
        path: String,
        definitions: [String: [String: Any]],
        into inventory: inout Set<String>
    ) throws {
        let known = Set([
            "type", "const", "enum", "pattern", "minimum", "maxLength",
            "properties", "required", "items", "contains", "additionalProperties",
            "unevaluatedProperties",
        ])
        guard Set(constraint.keys).subtracting(known).isEmpty else {
            throw GatewayProtocolError.invalidJSON
        }
        for keyword in constraint.keys {
            inventory.insert(occurrence(recordType, path, keyword))
        }
        if try schemaTypes(constraint).contains("null") {
            inventory.insert(occurrence(recordType, path, "nullable"))
        }
        if let properties = constraint["properties"] as? [String: [String: Any]] {
            for (field, property) in properties {
                try collectConstraintInventory(
                    resolvedSchema(property, definitions: definitions),
                    recordType: recordType,
                    path: path == "$record" ? field : "\(path).\(field)",
                    definitions: definitions,
                    into: &inventory
                )
            }
        }
        if let items = constraint["items"] as? [String: Any] {
            try collectConstraintInventory(
                resolvedSchema(items, definitions: definitions),
                recordType: recordType,
                path: "\(path)[]",
                definitions: definitions,
                into: &inventory
            )
        }
        if let contains = constraint["contains"] as? [String: Any] {
            try collectConstraintInventory(
                resolvedSchema(contains, definitions: definitions),
                recordType: recordType,
                path: "\(path)[contains]",
                definitions: definitions,
                into: &inventory
            )
        }
    }

    private func assertFieldParity(
        field: String,
        constraint: [String: Any],
        fixture: [String: Any],
        recordType: String,
        definitions: [String: [String: Any]],
        exercised: inout Set<String>
    ) throws {
        var workingFixture = fixture
        if workingFixture[field] == nil {
            workingFixture[field] = try validValue(
                for: constraint,
                definitions: definitions
            )
            _ = try decode(workingFixture)
        }
        let path = field
        let types = try schemaTypes(constraint)
        if types.contains("string") {
            expectDecodeFailure("\(recordType).\(field) is a string", object: replacing(
                field, with: 0, in: workingFixture
            ))
        } else if types.contains("integer") {
            expectDecodeFailure("\(recordType).\(field) is an integer", object: replacing(
                field, with: "fixture", in: workingFixture
            ))
        } else if types.contains("array") {
            expectDecodeFailure("\(recordType).\(field) is an array", object: replacing(
                field, with: [:], in: workingFixture
            ))
        } else if types.contains("object") {
            expectDecodeFailure("\(recordType).\(field) is an object", object: replacing(
                field, with: "fixture", in: workingFixture
            ))
        } else {
            throw GatewayProtocolError.invalidJSON
        }
        if constraint["type"] != nil {
            exercised.insert(occurrence(recordType, path, "type"))
        }

        if let constant = constraint["const"] {
            _ = try decode(replacing(field, with: constant, in: workingFixture))
            expectDecodeFailure("\(recordType).\(field) matches its constant", object: replacing(
                field, with: try differentValue(from: constant), in: workingFixture
            ))
            exercised.insert(occurrence(recordType, path, "const"))
        }
        if let values = constraint["enum"] as? [String] {
            let schemaValues = Set(values)
            #expect(
                GatewayRecord.enumValues(recordType: recordType, propertyPath: path)
                    == schemaValues
            )
            for value in values {
                _ = try decode(replacing(field, with: value, in: workingFixture))
            }
            expectDecodeFailure("\(recordType).\(field) matches its enum", object: replacing(
                field, with: differentString(from: schemaValues), in: workingFixture
            ))
            exercised.insert(occurrence(recordType, path, "enum"))
        }
        if constraint["pattern"] != nil {
            _ = try decode(replacing(field, with: session, in: workingFixture))
            expectDecodeFailure("\(recordType).\(field) matches its UUID pattern", object: replacing(
                field, with: "not-a-uuid", in: workingFixture
            ))
            exercised.insert(occurrence(recordType, path, "pattern"))
        }
        if let minimum = constraint["minimum"] as? NSNumber {
            _ = try decode(replacing(field, with: minimum.intValue, in: workingFixture))
            expectDecodeFailure("\(recordType).\(field) honors its minimum", object: replacing(
                field, with: minimum.intValue - 1, in: workingFixture
            ))
            exercised.insert(occurrence(recordType, path, "minimum"))
        }
        if let maximum = constraint["maxLength"] as? Int {
            _ = try decode(replacing(
                field,
                with: String(repeating: "x", count: maximum),
                in: workingFixture
            ))
            expectDecodeFailure("\(recordType).\(field) honors its maximum length", object: replacing(
                field,
                with: String(repeating: "x", count: maximum + 1),
                in: workingFixture
            ))
            exercised.insert(occurrence(recordType, path, "maxLength"))
        }
        if types.contains("null") {
            _ = try decode(replacing(field, with: NSNull(), in: workingFixture))
            exercised.insert(occurrence(recordType, path, "nullable"))
        }
        if types.contains("array") {
            try assertArrayParity(
                field: field,
                constraint: constraint,
                fixture: workingFixture,
                recordType: recordType,
                definitions: definitions,
                exercised: &exercised
            )
        }
        if types.contains("object") {
            try assertObjectParity(
                field: field,
                constraint: constraint,
                fixture: workingFixture,
                recordType: recordType,
                definitions: definitions,
                exercised: &exercised
            )
        }
    }

    private func assertOptionalParity(
        field: String,
        constraint: [String: Any],
        fixture: [String: Any]
    ) throws {
        if fixture[field] != nil {
            var missing = fixture
            missing.removeValue(forKey: field)
            _ = try decode(missing)
        } else {
            _ = try decode(replacing(field, with: try validValue(for: constraint), in: fixture))
        }
        if try schemaTypes(constraint).contains("null") {
            _ = try decode(replacing(field, with: NSNull(), in: fixture))
        }
    }

    private func assertArrayParity(
        field: String,
        constraint: [String: Any],
        fixture: [String: Any],
        recordType: String,
        definitions: [String: [String: Any]],
        exercised: inout Set<String>
    ) throws {
        let path = field
        if let rawContains = constraint["contains"] as? [String: Any] {
            let contains = try resolvedSchema(rawContains, definitions: definitions)
            let matching = try validValue(for: contains, definitions: definitions)
            _ = try decode(replacing(field, with: [matching], in: fixture))
            expectDecodeFailure("\(recordType).\(field) honors contains", object: replacing(
                field,
                with: [try differentValue(from: matching)],
                in: fixture
            ))
            exercised.insert(occurrence(recordType, path, "contains"))
            if contains["const"] != nil {
                exercised.insert(occurrence(recordType, "\(path)[contains]", "const"))
            }
        }
        guard let items = constraint["items"] as? [String: Any] else { return }
        exercised.insert(occurrence(recordType, path, "items"))
        let itemConstraint = try resolvedSchema(items, definitions: definitions)
        expectDecodeFailure("\(recordType).\(field) item kind matches", object: replacing(
            field, with: [try invalidValue(for: itemConstraint)], in: fixture
        ))
        if itemConstraint["type"] != nil {
            exercised.insert(occurrence(recordType, "\(path)[]", "type"))
        }
        guard try schemaTypes(itemConstraint).contains("object") else { return }
        guard let values = fixture[field] as? [Any],
              let first = values.first as? [String: Any]
        else {
            throw GatewayProtocolError.invalidJSON
        }
        try assertNestedObjectParity(
            first,
            field: field,
            constraint: itemConstraint,
            fixture: fixture,
            recordType: recordType,
            definitions: definitions,
            path: "\(path)[]",
            exercised: &exercised,
            replacingObject: { object in
                var replacement = values
                replacement[0] = object
                return replacing(field, with: replacement, in: fixture)
            }
        )
    }

    private func assertObjectParity(
        field: String,
        constraint: [String: Any],
        fixture: [String: Any],
        recordType: String,
        definitions: [String: [String: Any]],
        exercised: inout Set<String>
    ) throws {
        guard constraint["properties"] != nil else { return }
        guard let object = fixture[field] as? [String: Any] else {
            throw GatewayProtocolError.invalidJSON
        }
        try assertNestedObjectParity(
            object,
            field: field,
            constraint: constraint,
            fixture: fixture,
            recordType: recordType,
            definitions: definitions,
            path: field,
            exercised: &exercised
        )
    }

    private func assertNestedObjectParity(
        _ object: [String: Any],
        field: String,
        constraint: [String: Any],
        fixture: [String: Any],
        recordType: String,
        definitions: [String: [String: Any]],
        path: String,
        exercised: inout Set<String>,
        replacingObject: (([String: Any]) -> [String: Any])? = nil
    ) throws {
        let replaceObject = replacingObject ?? { object in
            replacing(field, with: object, in: fixture)
        }
        let properties = try schemaProperties(constraint)
        let required = try schemaRequired(constraint)
        exercised.insert(occurrence(recordType, path, "properties"))
        exercised.insert(occurrence(recordType, path, "required"))
        if constraint["additionalProperties"] as? Bool == false
            || constraint["unevaluatedProperties"] as? Bool == false
        {
            var unknown = object
            unknown["unclassified_nested_field"] = "fixture"
            expectDecodeFailure("\(recordType).\(field) is closed", object: replaceObject(unknown))
            if constraint["additionalProperties"] != nil {
                exercised.insert(occurrence(recordType, path, "additionalProperties"))
            }
            if constraint["unevaluatedProperties"] != nil {
                exercised.insert(occurrence(recordType, path, "unevaluatedProperties"))
            }
        }
        for nestedField in required {
            var missing = object
            missing.removeValue(forKey: nestedField)
            expectDecodeFailure("\(recordType).\(field) requires \(nestedField)", object: replaceObject(missing))
        }
        for (nestedField, rawConstraint) in properties {
            let nestedConstraint = try resolvedSchema(rawConstraint, definitions: definitions)
            let nestedPath = "\(path).\(nestedField)"
            var validObject = object
            if validObject[nestedField] == nil {
                validObject[nestedField] = try validValue(
                    for: nestedConstraint,
                    definitions: definitions
                )
                _ = try decode(replaceObject(validObject))
            }
            var invalid = object
            invalid[nestedField] = try invalidValue(for: nestedConstraint)
            expectDecodeFailure("\(recordType).\(field).\(nestedField) matches", object: replaceObject(invalid))
            if nestedConstraint["type"] != nil {
                exercised.insert(occurrence(recordType, nestedPath, "type"))
            }
            if let constant = nestedConstraint["const"] {
                var candidate = validObject
                candidate[nestedField] = constant
                _ = try decode(replaceObject(candidate))
                candidate[nestedField] = try differentValue(from: constant)
                expectDecodeFailure("\(recordType).\(nestedPath) const matches", object: replaceObject(candidate))
                exercised.insert(occurrence(recordType, nestedPath, "const"))
            }
            if let values = nestedConstraint["enum"] as? [String] {
                let schemaValues = Set(values)
                #expect(
                    GatewayRecord.enumValues(recordType: recordType, propertyPath: nestedPath)
                        == schemaValues
                )
                for value in values {
                    var candidate = validObject
                    candidate[nestedField] = value
                    _ = try decode(replaceObject(candidate))
                }
                invalid = validObject
                invalid[nestedField] = differentString(from: schemaValues)
                expectDecodeFailure("\(recordType).\(field).\(nestedField) enum matches", object: replaceObject(invalid))
                exercised.insert(occurrence(recordType, nestedPath, "enum"))
            }
            if nestedConstraint["pattern"] != nil {
                invalid = validObject
                invalid[nestedField] = "not-a-uuid"
                expectDecodeFailure("\(recordType).\(field).\(nestedField) UUID matches", object: replaceObject(invalid))
                exercised.insert(occurrence(recordType, nestedPath, "pattern"))
            }
            if let minimum = nestedConstraint["minimum"] as? NSNumber {
                var candidate = validObject
                candidate[nestedField] = minimum.intValue
                _ = try decode(replaceObject(candidate))
                candidate[nestedField] = minimum.intValue - 1
                expectDecodeFailure("\(recordType).\(nestedPath) minimum matches", object: replaceObject(candidate))
                exercised.insert(occurrence(recordType, nestedPath, "minimum"))
            }
            if let maximum = nestedConstraint["maxLength"] as? Int {
                var candidate = validObject
                candidate[nestedField] = String(repeating: "x", count: maximum)
                _ = try decode(replaceObject(candidate))
                candidate[nestedField] = String(repeating: "x", count: maximum + 1)
                expectDecodeFailure("\(recordType).\(nestedPath) maxLength matches", object: replaceObject(candidate))
                exercised.insert(occurrence(recordType, nestedPath, "maxLength"))
            }
            if try schemaTypes(nestedConstraint).contains("null") {
                var candidate = validObject
                candidate[nestedField] = NSNull()
                _ = try decode(replaceObject(candidate))
                exercised.insert(occurrence(recordType, nestedPath, "nullable"))
            }
        }
        if field == "provider_profile" {
            var nullableURL = object
            nullableURL["base_url"] = "https://example.invalid"
            _ = try decode(replacing(field, with: nullableURL, in: fixture))
            nullableURL["base_url"] = NSNull()
            _ = try decode(replacing(field, with: nullableURL, in: fixture))
            nullableURL["base_url"] = 0
            expectDecodeFailure("\(recordType).\(field).base_url is nullable string", object: replacing(
                field, with: nullableURL, in: fixture
            ))
        }
    }

    private func schemaTypes(_ constraint: [String: Any]) throws -> Set<String> {
        if let type = constraint["type"] as? String { return [type] }
        if let types = constraint["type"] as? [String] { return Set(types) }
        if let constant = constraint["const"] {
            switch constant {
            case is String: return ["string"]
            case is NSNumber: return ["integer"]
            case is NSNull: return ["null"]
            default: throw GatewayProtocolError.invalidJSON
            }
        }
        if let values = constraint["enum"] as? [String], !values.isEmpty {
            return ["string"]
        }
        throw GatewayProtocolError.invalidJSON
    }

    private func validValue(
        for constraint: [String: Any],
        definitions: [String: [String: Any]] = [:]
    ) throws -> Any {
        if let constant = constraint["const"] {
            return constant
        }
        if let values = constraint["enum"] as? [String], let first = values.first {
            return first
        }
        if constraint["pattern"] != nil { return session }
        let types = try schemaTypes(constraint)
        if types.contains("string") { return "fixture" }
        if types.contains("integer") {
            return (constraint["minimum"] as? NSNumber)?.intValue ?? 0
        }
        if types.contains("array") {
            if let rawContains = constraint["contains"] as? [String: Any] {
                let contains = definitions.isEmpty
                    ? rawContains
                    : try resolvedSchema(rawContains, definitions: definitions)
                return [try validValue(for: contains, definitions: definitions)]
            }
            return []
        }
        if types.contains("object") {
            let properties = constraint["properties"] as? [String: [String: Any]] ?? [:]
            let required = constraint["required"] as? [String] ?? []
            var object: [String: Any] = [:]
            for field in required {
                guard let raw = properties[field] else {
                    throw GatewayProtocolError.invalidJSON
                }
                let nested = definitions.isEmpty
                    ? raw
                    : try resolvedSchema(raw, definitions: definitions)
                object[field] = try validValue(for: nested, definitions: definitions)
            }
            return object
        }
        if types.contains("null") { return NSNull() }
        throw GatewayProtocolError.invalidJSON
    }

    private func invalidValue(for constraint: [String: Any]) throws -> Any {
        let types = try schemaTypes(constraint)
        if types.contains("string") { return 0 }
        if types.contains("integer") { return "fixture" }
        if types.contains("array") { return [:] }
        if types.contains("object") { return "fixture" }
        throw GatewayProtocolError.invalidJSON
    }

    private func differentValue(from constant: Any) throws -> Any {
        switch constant {
        case let value as String:
            return value + "-different"
        case let value as NSNumber:
            return value.intValue + 1
        case is NSNull:
            return "fixture"
        default:
            throw GatewayProtocolError.invalidJSON
        }
    }

    private func differentString(from values: Set<String>) -> String {
        var candidate = "__schema_counterexample__"
        while values.contains(candidate) {
            candidate += "_"
        }
        return candidate
    }

    private func occurrence(
        _ recordType: String,
        _ path: String,
        _ keyword: String
    ) -> String {
        "\(recordType)/\(path)/\(keyword)"
    }

    private func replacing(
        _ field: String,
        with value: Any,
        in object: [String: Any]
    ) -> [String: Any] {
        var replacement = object
        replacement[field] = value
        return replacement
    }

    private func decode(_ object: [String: Any]) throws -> GatewayRecord {
        try GatewayRecord.decode(JSONSerialization.data(withJSONObject: object))
    }

    private func expectDecodeFailure(_ label: String, object: [String: Any]) {
        expectThrows(label) { _ = try decode(object) }
    }

    private func ready() throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "gateway.ready",
            sessionID: session,
            fields: [
                "helper_version": .string("fake-1"),
                "supported_protocols": .array([.integer(1)]),
            ]
        )
    }

    private func readinessResult(status: String) throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "provider.readiness_result",
            sessionID: session,
            requestID: request,
            fields: ["status": .string(status)]
        )
    }

    private func accepted(
        sessionID: String? = nil,
        requestID: String? = nil,
        turnID: String? = nil,
        generation: Int = 1
    ) throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "reasoning.accepted",
            sessionID: sessionID ?? session,
            requestID: requestID ?? request,
            fields: [
                "turn_id": .string(turnID ?? turn),
                "generation": .integer(generation),
            ]
        )
    }

    private func delta(ordinal: Int) throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "reasoning.text_delta",
            sessionID: session,
            requestID: request,
            fields: [
                "turn_id": .string(turn),
                "generation": .integer(1),
                "ordinal": .integer(ordinal),
                "text": .string("hello"),
            ]
        )
    }

    private func usage() throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "reasoning.usage",
            sessionID: session,
            requestID: request,
            fields: [
                "turn_id": .string(turn),
                "generation": .integer(1),
            ]
        )
    }

    private func completed() throws -> GatewayRecord {
        try GatewayRecord.make(
            type: "reasoning.completed",
            sessionID: session,
            requestID: request,
            fields: [
                "turn_id": .string(turn),
                "generation": .integer(1),
            ]
        )
    }

    private func expectThrows(
        _ label: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("Expected error: \(label)")
        } catch {}
    }
}

private struct HostileCorpus: Decodable {
    let invalid: [HostileCase]
}

private struct HostileCase: Decodable {
    let id: String
    let kind: String
    let file: String?
    let phase: String?
    let hex: String?
    let byte: UInt8?
    let count: Int?
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor..<next], radix: 16)!)
            cursor = next
        }
        self.init(bytes)
    }
}
