import Foundation

/// The AI's plan for the current request, shown pinned at the top of the chat as a progress bar and step list:
/// what it is doing, which step it is on, what is done and what is left. It comes from the chat-only
/// `update_plan` tool, which the model calls at the start of any multi-step job and again as steps finish. The call
/// returns at once (the turn goes on); each call replaces the whole plan.
public struct ChatPlan: Codable, Equatable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable { case pending, active, done, skipped }

    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public var title: String
        public var status: Status
        /// A short line under the step (what came out of it, what it waits on).
        public var note: String?
        public var id: String { title }

        public init(title: String, status: Status = .pending, note: String? = nil) {
            self.title = title; self.status = status; self.note = note
        }
    }

    /// What the whole job is, in a few words.
    public var goal: String
    public var steps: [Step]
    /// Waiting on the user (a question card is up): the bar says so.
    public var waiting: Bool = false

    public init(goal: String, steps: [Step], waiting: Bool = false) {
        self.goal = goal; self.steps = steps; self.waiting = waiting
    }

    enum CodingKeys: String, CodingKey { case goal, steps, waiting }

    /// Lenient: a plan saved without `waiting` (or a goal) still loads, so the chat file always opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
    }

    public var doneCount: Int { steps.filter { $0.status == .done || $0.status == .skipped }.count }
    public var activeIndex: Int? { steps.firstIndex { $0.status == .active } }
    public var isComplete: Bool { !steps.isEmpty && doneCount == steps.count }

    /// 0…1, counting an active step as half done.
    public var fraction: Double {
        guard !steps.isEmpty else { return 0 }
        return (Double(doneCount) + (activeIndex == nil ? 0 : 0.5)) / Double(steps.count)
    }

    /// The step being worked on, else the next one waiting.
    public var current: Step? {
        activeIndex.map { steps[$0] } ?? steps.first { $0.status == .pending }
    }

    public static let toolName = "update_plan"

    /// The tool definition sent with every request (handled by the chat, not the MCP server).
    public static var tool: JSONValue {
        [
            "name": .string(toolName),
            "description": .string(
                "Show the user your plan as a progress bar pinned at the top of the chat. Call it before the first real step of any job with 3+ steps (a new scene, a set of assets, a 3D space, a multi-part fix), listing every step in order, including the direction stages you will ask about; call it again whenever a step starts or ends, or the plan changes. Each call replaces the plan: send all steps every time. Exactly one step active while working. Step titles: 2–6 words, the user's language. It returns at once; keep working."
            ),
            "input_schema": [
                "type": "object",
                "properties": [
                    "goal": ["type": "string", "description": "The whole job in a few words"],
                    "steps": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string", "description": "2–6 words"],
                                "status": [
                                    "type": "string", "enum": .array(Status.allCases.map { .string($0.rawValue) }),
                                ],
                                "note": ["type": "string", "description": "Optional short result or blocker"],
                            ],
                            "required": ["title", "status"],
                        ],
                    ],
                ],
                "required": ["goal", "steps"],
            ],
            "eager_input_streaming": true,
        ]
    }

    /// Reads an `update_plan` call. Throws a message for the model when the input can't be shown.
    public static func parse(_ input: [String: JSONValue]) throws -> ChatPlan {
        let goal = input["goal"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var steps: [Step] = []
        for (i, s) in (input["steps"]?.array ?? []).enumerated() {
            guard let t = s["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                throw ChatPlanError("step \(i + 1) needs a title")
            }
            let status = s["status"]?.string.flatMap(Status.init(rawValue:)) ?? .pending
            // Titles are the ids: a repeated one gets its number.
            let title = steps.contains { $0.title == t } ? "\(t) (\(i + 1))" : t
            steps.append(Step(title: title, status: status, note: s["note"]?.string))
        }
        guard !steps.isEmpty else { throw ChatPlanError("give at least one step") }
        if steps.count > 15 { throw ChatPlanError("at most 15 steps") }
        return ChatPlan(goal: goal, steps: steps)
    }

    /// What the model reads back.
    public static let ack = "Shown to the user. Keep working; call update_plan again when a step starts or ends."
}

public struct ChatPlanError: Error, CustomStringConvertible {
    public let description: String
    init(_ s: String) { description = "update_plan: " + s }
}
