import ArclightCore
import Foundation

/// A failure reported to the agent as an `isError` tool result; the message is shown verbatim.
struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: Helpers for tool definitions

/// A tool result made of one text content block.
func text(_ s: String) -> [JSONValue] { [["type": "text", "text": .string(s)]] }

/// Sorted-key one-line JSON, so tool output is stable between runs.
func compactJSON<T: Encodable>(_ v: T) -> String {
    (try? String(data: JSONFormat.compact().encode(v), encoding: .utf8)) ?? "{}"
}

/// JSON Schema for a tool's arguments.
func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
    ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
}

/// One property in a tool schema; `extra` adds keys such as `enum` or `items`.
func prop(_ type: String, _ desc: String, extra: [String: JSONValue] = [:]) -> JSONValue {
    var o: [String: JSONValue] = ["type": .string(type), "description": .string(desc)]
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

extension Dictionary where Key == String, Value == JSONValue {
    func str(_ k: String) throws -> String {
        guard let v = self[k]?.string, !v.isEmpty else { throw ToolError("missing '\(k)'") }
        return v
    }
}
