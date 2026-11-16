import Foundation
import Testing

@testable import ArclightCore

/// Plays back canned assistant messages and records each request body.
private final class FakeStream: MessageStreaming, @unchecked Sendable {
    var replies: [Result<StreamedMessage, ChatAPIError>]
    var bodies: [JSONValue] = []
    var betas: [[String]] = []
    init(_ replies: [Result<StreamedMessage, ChatAPIError>]) { self.replies = replies }

    func stream(
        _ body: JSONValue, beta: [String], onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws
        -> StreamedMessage
    {
        bodies.append(body)
        betas.append(beta)
        let r = replies.removeFirst()
        if case .success(let m) = r {
            for b in m.content where b["type"]?.string == "text" { onEvent(.text(b["text"]?.string ?? "")) }
        }
        return try r.get()
    }
}

private final class FakeTools: ChatToolRunner, @unchecked Sendable {
    var tools = [
        MCPToolInfo(name: "scene_get", description: "read", inputSchema: ["type": "object"]),
        MCPToolInfo(name: "render_frames", description: "render", inputSchema: ["properties": [:]]),
    ]
    var instructions = "SERVER NOTES"
    var calls: [(String, [String: JSONValue])] = []
    var onCall: (() -> Void)?
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> (content: [JSONValue], isError: Bool) {
        calls.append((name, arguments))
        onCall?()
        if name == "render_frames" {
            return (
                [["type": "text", "text": "rendered"], ["type": "image", "data": "AAEC", "mimeType": "image/jpeg"]],
                false
            )
        }
        return ([["type": "text", "text": "scene a"]], false)
    }
}

private func message(_ content: [JSONValue], stop: String, invalid: Set<String> = []) -> StreamedMessage {
    var m = StreamedMessage()
    m.content = content
    m.stopReason = stop
    m.invalidToolInputs = invalid
    return m
}

private func toolUse(_ id: String, _ name: String, _ input: JSONValue = [:]) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
}

private final class Events: @unchecked Sendable {
    var all: [ChatEvent] = []
    let lock = NSLock()
    func add(_ e: ChatEvent) { lock.withLock { all.append(e) } }
}

@Suite struct ChatEngineTests {
    private func backend(_ stream: FakeStream, _ tools: FakeTools, model: ChatModel = .opus) -> APIChatBackend {
        let b = APIChatBackend(
            client: stream, runner: tools, model: model, effort: .medium, projectPath: "/p.arclight", history: [])
        b.retryDelays = [0, 0]
        return b
    }

    @Test func toolLoopSendsAllResultsInOneMessageAndConvertsImages() async throws {
        let s = FakeStream([
            .success(
                message(
                    [
                        ["type": "thinking", "thinking": "plan", "signature": "sig"], toolUse("t1", "scene_get"),
                        toolUse("t2", "render_frames", ["scale": 0.25]),
                    ], stop: "tool_use")),
            .success(message([["type": "text", "text": "Done."]], stop: "end_turn")),
        ])
        let tools = FakeTools()
        let b = backend(s, tools)
        let ev = Events()
        try await b.send("make it red", context: "<editor>x</editor>", onEvent: { ev.add($0) })

        #expect(tools.calls.map(\.0) == ["scene_get", "render_frames"])
        #expect(b.history.count == 4)  // user, assistant(tool_use), user(results), assistant(text)
        let results = try #require(b.history[2]["content"]?.array)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0["type"]?.string == "tool_result" })
        let img = try #require(results[1]["content"]?.array?.last)
        #expect(img["type"]?.string == "image")
        #expect(img["source"]?["media_type"]?.string == "image/jpeg")
        // The thinking block goes back unchanged.
        #expect(b.history[1]["content"]?.array?.first?["signature"]?.string == "sig")
        // Editor note first, then the user's words.
        #expect(
            b.history[0]["content"]?.array?.map { $0["text"]?.string ?? "" } == ["<editor>x</editor>", "make it red"])
        #expect(ev.all.contains(.toolEnd(id: "t2", ok: true, summary: "rendered", image: Data([0, 1, 2]))))
        #expect(ev.all.last == .text("Done."))
    }

    @Test func historyIsAppendOnlyAcrossTurns() async throws {
        let s = FakeStream([
            .success(message([toolUse("t1", "scene_get")], stop: "tool_use")),
            .success(message([["type": "text", "text": "a"]], stop: "end_turn")),
            .success(message([["type": "text", "text": "b"]], stop: "end_turn")),
        ])
        let b = backend(s, FakeTools())
        try await b.send("one", context: nil, onEvent: { _ in })
        let first = b.history
        try await b.send("two", context: nil, onEvent: { _ in })
        #expect(Array(b.history.prefix(first.count)) == first)
        // Each request's messages extend the previous request's.
        let m1 = try #require(s.bodies[1]["messages"]?.array), m2 = try #require(s.bodies[2]["messages"]?.array)
        #expect(Array(m2.prefix(m1.count)) == m1)
    }

    @Test func attachmentsGoBeforeTheTextAndAloneNeedNoText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".arclight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ChatAttachment.store(data: Data("%PDF-1.4".utf8), name: "brief.pdf", project: dir)
        let s = FakeStream([
            .success(message([["type": "text", "text": "a"]], stop: "end_turn")),
            .success(message([["type": "text", "text": "b"]], stop: "end_turn")),
        ])
        let b = backend(s, FakeTools())
        try await b.send("use this", attachments: [a], context: "<editor>x</editor>", onEvent: { _ in })
        let first = try #require(s.bodies[0]["messages"]?.array?.last?["content"]?.array)
        #expect(first.map { $0["type"]?.string } == ["text", "document", "text", "text"])
        #expect(first.last?["text"]?.string == "use this")
        try await b.send("", attachments: [a], context: nil, onEvent: { _ in })
        let second = try #require(s.bodies[1]["messages"]?.array?.last?["content"]?.array)
        #expect(second.map { $0["type"]?.string } == ["document", "text"])
    }

    @Test func invalidToolInputIsAnErrorResultAndNotRun() async throws {
        let s = FakeStream([
            .success(message([toolUse("t1", "scene_get")], stop: "tool_use", invalid: ["t1"])),
            .success(message([["type": "text", "text": "ok"]], stop: "end_turn")),
        ])
        let tools = FakeTools()
        let b = backend(s, tools)
        try await b.send("x", context: nil, onEvent: { _ in })
        #expect(tools.calls.isEmpty)
        #expect(b.history[2]["content"]?.array?.first?["is_error"]?.bool == true)
    }

    @Test func requestBodyIsCacheFriendlyAndUsesCurrentAPIShape() async throws {
        let s = FakeStream([.success(message([["type": "text", "text": "hi"]], stop: "end_turn"))])
        try await backend(s, FakeTools()).send("x", context: nil, onEvent: { _ in })
        let body = try #require(s.bodies.first)
        #expect(body["model"]?.string == "claude-opus-5-5")
        #expect(body["stream"]?.bool == true)
        #expect(body["thinking"]?["type"]?.string == "adaptive")
        #expect(body["output_config"]?["effort"]?.string == "medium")
        #expect(body["cache_control"]?["type"]?.string == "ephemeral")
        #expect(body["fallbacks"]?.string == "default")
        #expect(s.betas.first == ["server-side-fallback-2026-07-01"])
        let tools = try #require(body["tools"]?.array)
        #expect(tools.map { $0["name"]?.string ?? "" } == ["render_frames", "scene_get", "ask_choice"])
        #expect(tools.allSatisfy { $0["eager_input_streaming"]?.bool == true })
        #expect(tools.allSatisfy { $0["input_schema"]?["type"]?.string == "object" })
        #expect(body["system"]?.array?.first?["text"]?.string?.contains("SERVER NOTES") == true)
    }

    @Test func haikuHasNoFallback() async throws {
        let s = FakeStream([.success(message([["type": "text", "text": "hi"]], stop: "end_turn"))])
        try await backend(s, FakeTools(), model: .haiku).send("x", context: nil, onEvent: { _ in })
        #expect(s.bodies.first?["fallbacks"] == nil)
        #expect(s.betas.first == [])
    }

    @Test func busyServiceIsRetriedAndBadKeyIsNot() async throws {
        let s = FakeStream([
            .failure(.http(529, "overloaded")), .success(message([["type": "text", "text": "hi"]], stop: "end_turn")),
        ])
        let ev = Events()
        try await backend(s, FakeTools()).send("x", context: nil, onEvent: { ev.add($0) })
        #expect(s.bodies.count == 2)
        #expect(ev.all.contains(.notice("The AI service is busy — trying again…")))

        let bad = FakeStream([.failure(.badKey("invalid x-api-key"))])
        let b = backend(bad, FakeTools())
        await #expect(throws: ChatAPIError.self) { try await b.send("x", context: nil, onEvent: { _ in }) }
        #expect(bad.bodies.count == 1)
    }

    @Test func aFailedTurnIsMergedIntoTheNextUserMessage() async throws {
        let s = FakeStream([
            .failure(.badKey("nope")), .success(message([["type": "text", "text": "hi"]], stop: "end_turn")),
        ])
        let b = backend(s, FakeTools())
        _ = try? await b.send("first", context: nil, onEvent: { _ in })
        try await b.send("second", context: nil, onEvent: { _ in })
        #expect(b.history.count == 2)
        #expect(b.history[0]["content"]?.array?.count == 2)
    }

    @Test func refusalIsReportedAndToolsDontRun() async throws {
        var m = message([toolUse("t1", "scene_get")], stop: "refusal")
        m.stopDetails = ["type": "refusal", "category": "cyber"]
        let tools = FakeTools()
        let ev = Events()
        let b = backend(FakeStream([.success(m)]), tools)
        try await b.send("x", context: nil, onEvent: { ev.add($0) })
        #expect(tools.calls.isEmpty)
        #expect(ev.all.contains(.notice("The model declined this request (cyber).")))
        #expect(b.history.last?["content"]?.array?.first?["is_error"]?.bool == true)
    }

    @Test func stoppingDuringToolsAnswersEveryCall() async throws {
        let s = FakeStream([
            .success(message([toolUse("t1", "scene_get"), toolUse("t2", "scene_get")], stop: "tool_use"))
        ])
        let tools = FakeTools()
        let b = backend(s, tools)
        let task = Task { try await b.send("x", context: nil, onEvent: { _ in }) }
        tools.onCall = { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(tools.calls.count == 1)
        let results = try #require(b.history.last?["content"]?.array)
        #expect(results.count == 2)
        #expect(results[1]["is_error"]?.bool == true)
    }
}

/// Direction stages: ask_choice ends the turn, and the user's answer goes back as that call's result.
@Suite struct ChatChoiceEngineTests {
    private func backend(_ stream: FakeStream, _ tools: FakeTools) -> APIChatBackend {
        let b = APIChatBackend(
            client: stream, runner: tools, model: .opus, effort: .medium, projectPath: "/p.arclight", history: [])
        b.retryDelays = [0, 0]
        return b
    }

    private let ask: JSONValue = [
        "stage": "look", "question": "Which look?",
        "options": [
            ["id": "look-a", "title": "Neon grid", "note": "dark, cyan", "visual": ["scene": "look-a", "time": 0.5]],
            ["id": "look-b", "title": "Paper", "visual": ["scene": "look-b"]],
        ],
    ]

    @Test func askChoiceStopsTheTurnAndTheAnswerBecomesItsResult() async throws {
        let s = FakeStream([
            .success(message([toolUse("t1", "scene_get"), toolUse("c1", "ask_choice", ask)], stop: "tool_use")),
            .success(message([["type": "text", "text": "Building it."]], stop: "end_turn")),
        ])
        let tools = FakeTools()
        let b = backend(s, tools)
        let events = Events()
        try await b.send("make an intro", context: "<editor>x</editor>") { events.add($0) }
        // Only the real tool ran; the question reached the UI and nothing else was requested.
        #expect(tools.calls.map(\.0) == ["scene_get"])
        #expect(s.bodies.count == 1)
        guard case .choice(let c)? = events.all.last else { Issue.record("no choice event"); return }
        #expect(c.id == "c1" && c.stage == .look && c.options.map(\.id) == ["look-a", "look-b"])
        #expect(c.options[0].visual == ChatChoice.Visual(scene: "look-a", times: [0.5]))
        #expect(c.options[1].visual?.times == [0])
        #expect(APIChatBackend.unanswered(b.history) == ["c1"])
        // The answer joins scene_get's result in one user message, results first, then the editor note.
        let answer = c.resultText(.init(picked: ["look-b"], comment: "warmer"))
        try await b.send(answer, context: "<editor>y</editor>") { events.add($0) }
        let msgs = s.bodies[1]["messages"]?.array ?? []
        #expect(msgs.map { $0["role"]?.string ?? "" } == ["user", "assistant", "user"])
        let last = msgs[2]["content"]?.array ?? []
        #expect(last.map { $0["type"]?.string ?? "" } == ["tool_result", "tool_result", "text"])
        #expect(last[0]["tool_use_id"]?.string == "t1")
        #expect(last[1]["tool_use_id"]?.string == "c1")
        #expect(last[1]["content"]?.string == "Look: the user picked look-b (“Paper”). Their comment: warmer")
        #expect(last[2]["text"]?.string == "<editor>y</editor>")
        #expect(APIChatBackend.unanswered(b.history).isEmpty)
        // The tool is offered on every request.
        let names = s.bodies[0]["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("ask_choice"))
    }

    @Test func aChoiceAloneAddsNoEmptyUserMessage() async throws {
        let s = FakeStream([
            .success(
                message(
                    [toolUse("c1", "ask_choice", ["stage": "brief", "question": "OK?", "body": "6s, bold"])],
                    stop: "tool_use")),
            .success(message([["type": "text", "text": "ok"]], stop: "end_turn")),
        ])
        let b = backend(s, FakeTools())
        try await b.send("go", context: nil) { _ in }
        #expect(b.history.last?["role"]?.string == "assistant")
        try await b.send("Brief: the user confirmed it as is.", context: nil) { _ in }
        let msgs = s.bodies[1]["messages"]?.array ?? []
        #expect(msgs.count == 3)
        #expect(msgs[2]["content"]?.array?.first?["tool_use_id"]?.string == "c1")
    }

    @Test func aBadQuestionGoesBackToTheModelAsAnError() async throws {
        let s = FakeStream([
            .success(message([toolUse("c1", "ask_choice", ["stage": "colour", "question": "?"])], stop: "tool_use")),
            .success(message([["type": "text", "text": "sorry"]], stop: "end_turn")),
        ])
        let events = Events()
        let b = backend(s, FakeTools())
        try await b.send("go", context: nil) { events.add($0) }
        #expect(s.bodies.count == 2)
        #expect(!events.all.contains { if case .choice = $0 { return true } else { return false } })
        let r = s.bodies[1]["messages"]?.array?.last?["content"]?.array?.first
        #expect(r?["is_error"]?.bool == true)
        #expect(r?["content"]?.string?.contains("stage must be") == true)
    }

    @Test func twoQuestionsAtOnceAskOnlyTheFirst() async throws {
        let s = FakeStream([
            .success(
                message(
                    [
                        toolUse("c1", "ask_choice", ask),
                        toolUse("c2", "ask_choice", ["stage": "motion", "question": "?"]),
                    ],
                    stop: "tool_use")),
            .success(message([["type": "text", "text": "ok"]], stop: "end_turn")),
        ])
        let events = Events()
        let b = backend(s, FakeTools())
        try await b.send("go", context: nil) { events.add($0) }
        guard case .choice(let c)? = events.all.last else { Issue.record("no choice"); return }
        #expect(c.id == "c1")
        #expect(APIChatBackend.unanswered(b.history) == ["c1"])
        try await b.send("Look: the user picked look-a (“Neon grid”).", context: nil) { _ in }
        let last = s.bodies[1]["messages"]?.array?.last?["content"]?.array ?? []
        #expect(Set(last.compactMap { $0["tool_use_id"]?.string }) == ["c1", "c2"])
    }
}

@Suite struct ChatChoiceTests {
    @Test func answersReadAsPlainSentences() throws {
        let brief = ChatChoice(id: "b", stage: .brief, question: "Right?", body: "x")
        #expect(brief.resultText(.init()) == "Brief: the user confirmed it as is.")
        #expect(brief.resultText(.init(comment: " shorter ")) == "Brief: the user wants changes: shorter")
        let look = try ChatChoice.parse(
            id: "l", input: ["stage": "look", "question": "Which?", "options": [["title": "One"], ["title": "Two"]]])
        #expect(look.options.map(\.id) == ["A", "B"])
        #expect(look.resultText(.init(picked: ["B"])) == "Look: the user picked B (“Two”).")
        #expect(
            look.resultText(.init(comment: "neither"))
                == "Look: the user picked none of the options. Their comment: neither")
        #expect(
            look.resultText(.init(comment: "red", typed: true)) == "Look: the user answered in their own words: red")
        #expect(throws: ChatChoiceError.self) {
            try ChatChoice.parse(
                id: "x",
                input: [
                    "stage": "look", "question": "?",
                    "options": [["id": "a", "title": "1"], ["id": "a", "title": "2"]],
                ])
        }
        #expect(throws: ChatChoiceError.self) {
            try ChatChoice.parse(
                id: "x", input: ["stage": "look", "question": "?", "options": [["title": "1", "visual": ["time": 1]]]])
        }
    }

    @Test func transcriptKeepsChoicesAndKnowsWhatIsWaiting() throws {
        var t = ChatTranscript()
        t.items.append(ChatItem(kind: .user, text: "intro"))
        let c = ChatChoice(id: "c1", stage: .look, question: "Which?", options: [.init(id: "a", title: "A")])
        t.apply(.choice(c))
        #expect(t.pendingChoice?.id == "c1")
        let data = try JSONEncoder().encode(t)
        var back = try JSONDecoder().decode(ChatTranscript.self, from: data)
        #expect(back.items.last?.choice == c)
        #expect(back.pendingChoice?.id == "c1")
        back.answer("c1", .init(picked: ["a"]))
        #expect(back.pendingChoice == nil)
        #expect(back.items.last?.choice?.answer?.picked == ["a"])
        #expect(ChatPrompt.directionNote([.look, .motion]) == "<direction>ask first: look, motion</direction>")
        #expect(ChatPrompt.directionNote([]).contains("off"))
    }
}
