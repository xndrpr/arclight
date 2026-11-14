import Foundation

/// A question the AI asks in the chat at one of the direction stages (brief, look, storyboard, motion; see the
/// MCP guide's "direction" topic), shown as a card the user answers with a click. It comes from the chat-only
/// `ask_choice` tool: the turn stops there, and the answer goes back as that call's result on the next turn.
public struct ChatChoice: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case brief, look, storyboard, motion

        public var label: String {
            switch self {
            case .brief: return "Brief"
            case .look: return "Look"
            case .storyboard: return "Storyboard"
            case .motion: return "Motion feel"
            }
        }
    }

    /// What a tile shows: a still of a scene, a strip of stills (storyboard), or the scene looping (motion test).
    public struct Visual: Codable, Equatable, Sendable {
        public var scene: String
        public var times: [Double]
        public var loop: Bool

        public init(scene: String, times: [Double] = [0], loop: Bool = false) {
            self.scene = scene; self.times = times; self.loop = loop
        }
    }

    public struct Option: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var note: String?
        public var visual: Visual?

        public init(id: String, title: String, note: String? = nil, visual: Visual? = nil) {
            self.id = id; self.title = title; self.note = note; self.visual = visual
        }
    }

    public struct Answer: Codable, Equatable, Sendable {
        /// Ids of the picked options (empty for a brief, or when the user only commented).
        public var picked: [String]
        public var comment: String
        /// The user typed in the message field instead of using the card.
        public var typed: Bool

        public init(picked: [String] = [], comment: String = "", typed: Bool = false) {
            self.picked = picked; self.comment = comment; self.typed = typed
        }
    }

    /// The `tool_use` id: the answer is that call's result.
    public var id: String
    public var stage: Stage
    public var question: String
    /// Longer text under the question (the brief itself, at the brief stage).
    public var body: String?
    public var options: [Option]
    public var multiple: Bool
    public var answer: Answer?

    public init(
        id: String, stage: Stage, question: String, body: String? = nil, options: [Option] = [],
        multiple: Bool = false, answer: Answer? = nil
    ) {
        self.id = id; self.stage = stage; self.question = question; self.body = body; self.options = options
        self.multiple = multiple; self.answer = answer
    }

    public static let toolName = "ask_choice"

    /// The tool definition sent with every request (it isn't one of the MCP server's tools).
    public static var tool: JSONValue {
        let visual: JSONValue = [
            "type": "object",
            "description":
                "What the tile shows: a draft scene at time (a still), at times (a storyboard strip), or loop:true (plays it).",
            "properties": [
                "scene": ["type": "string", "description": "Draft scene id"],
                "time": ["type": "number", "description": "Seconds, for a still"],
                "times": ["type": "array", "items": ["type": "number"], "description": "Seconds, for a strip"],
                "loop": ["type": "boolean", "description": "Play the scene on a loop (motion tests)"],
            ],
            "required": ["scene"],
        ]
        let option: JSONValue = [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Short id, e.g. the draft scene id"],
                "title": ["type": "string", "description": "2–4 words"],
                "note": ["type": "string", "description": "One line on the idea"],
                "visual": visual,
            ],
            "required": ["id", "title"],
        ]
        return [
            "name": .string(toolName),
            "description": .string(
                "Ask the user to decide one direction stage (see guide direction) with a card in the chat: they click an option and may add a comment. "
                    + "Your turn ends here; their answer arrives as this call's result. Use it only at the stages, one question at a time, after checking the drafts yourself."
            ),
            "input_schema": [
                "type": "object",
                "properties": [
                    "stage": ["type": "string", "enum": .array(Stage.allCases.map { .string($0.rawValue) })],
                    "question": ["type": "string", "description": "One short question"],
                    "body": ["type": "string", "description": "Text shown under it (the brief, at the brief stage)"],
                    "options": ["type": "array", "items": option, "description": "Empty for the brief: confirm or change"],
                    "multiple": ["type": "boolean", "description": "Let the user pick more than one"],
                ],
                "required": ["stage", "question"],
            ],
            "eager_input_streaming": true,
        ]
    }

    /// Reads an `ask_choice` call. Throws a message for the model when the input can't be shown.
    public static func parse(id: String, input: [String: JSONValue]) throws -> ChatChoice {
        guard let s = input["stage"]?.string, let stage = Stage(rawValue: s) else {
            throw ChatChoiceError("stage must be one of brief, look, storyboard, motion")
        }
        guard let q = input["question"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            throw ChatChoiceError("question is required")
        }
        var options: [Option] = []
        for (i, o) in (input["options"]?.array ?? []).enumerated() {
            guard let title = o["title"]?.string, !title.isEmpty else { throw ChatChoiceError("option \(i): title is required") }
            let oid = o["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? String(UnicodeScalar(UInt8(65 + i % 26)))
            if options.contains(where: { $0.id == oid }) { throw ChatChoiceError("option ids must differ ('\(oid)')") }
            var visual: Visual?
            if let v = o["visual"]?.object {
                guard let scene = v["scene"]?.string, !scene.isEmpty else {
                    throw ChatChoiceError("option \(oid): visual needs a scene")
                }
                let times = v["times"]?.array?.compactMap(\.double) ?? v["time"]?.double.map { [$0] } ?? [0]
                visual = Visual(scene: scene, times: Array(times.prefix(8)), loop: v["loop"]?.bool ?? false)
            }
            options.append(Option(id: oid, title: title, note: o["note"]?.string, visual: visual))
        }
        if options.count > 6 { throw ChatChoiceError("at most 6 options") }
        return ChatChoice(
            id: id, stage: stage, question: q, body: input["body"]?.string, options: options,
            multiple: input["multiple"]?.bool ?? false)
    }

    /// The answer in words, as the tool result the model reads.
    public func resultText(_ a: Answer) -> String {
        let comment = a.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.typed { return "\(stage.label): the user answered in their own words: \(comment)" }
        if options.isEmpty {
            return comment.isEmpty
                ? "\(stage.label): the user confirmed it as is."
                : "\(stage.label): the user wants changes: \(comment)"
        }
        let picked = a.picked.compactMap { id in options.first { $0.id == id } }
        var s: String
        if picked.isEmpty {
            s = "\(stage.label): the user picked none of the options."
        } else {
            s = "\(stage.label): the user picked " + picked.map { "\($0.id) (“\($0.title)”)" }.joined(separator: " and ")
                + "."
        }
        if !comment.isEmpty { s += " Their comment: \(comment)" }
        return s
    }
}

public struct ChatChoiceError: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = "ask_choice: " + s }
}
