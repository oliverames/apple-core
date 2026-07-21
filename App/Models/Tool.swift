import Foundation
import JSONSchema
import MCP
import Ontology

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let outputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    private let implementation: @Sendable ([String: Value]) async throws -> Value

    public init<T: Encodable>(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        outputSchema: JSONSchema? = nil,
        annotations: MCP.Tool.Annotations,
        implementation: @Sendable @escaping ([String: Value]) async throws -> T
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema ?? Self.defaultOutputSchema
        self.annotations = annotations
        self.implementation = { input in
            let result = try await implementation(input)

            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            let data = try encoder.encode(result)

            let decoder = JSONDecoder()
            return try decoder.decode(Value.self, from: data)
        }
    }

    public func callAsFunction(_ input: [String: Value]) async throws -> Value {
        try await implementation(input)
    }

    private static var defaultOutputSchema: JSONSchema {
        .object(
            description: "A structured wrapper around the tool result.",
            properties: ["result": .any],
            required: ["result"],
            additionalProperties: false
        )
    }
}
