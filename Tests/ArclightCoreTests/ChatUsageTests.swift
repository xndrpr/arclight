import Foundation
import Testing

@testable import ArclightCore

/// Plays back one canned assistant message per request, with the usage a real stream would carry.
private final class UsageStream: MessageStreaming, @unchecked Sendable {
    var replies: [StreamedMessage]
    init(_ replies: [StreamedMessage]) { self.replies = replies }
    func stream(
        _ body: JSONValue, beta: [String], onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws -> StreamedMessage { replies.removeFirst() }
}

private final class NoTools: ChatToolRunner, @unchecked Sendable {
    var tools: [MCPToolInfo] = []
    var instructions = ""
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> (content: [JSONValue], isError: Bool) {
        ([["type": "text", "text": "ok"]], false)
    }
}

private final class Collected: @unchecked Sendable {
    var all: [ChatEvent] = []
    let lock = NSLock()
    func add(_ e: ChatEvent) { lock.withLock { all.append(e) } }
    var usage: [ChatUsage] { all.compactMap { if case .usage(let u) = $0 { return u } else { return nil } } }
}

private func feed(_ p: inout CLIStreamParser, _ lines: [String], now: Date = Date()) -> [ChatEvent] {
    lines.flatMap { p.feed(Data($0.utf8), now: now) }
}

@Suite struct ChatUsageCLITests {
    // Shaped like Claude Code 2.1.322's stream-json output (`claude -p --output-format stream-json --verbose
    // --include-partial-messages`).
    static let initLine =
        #"{"type":"system","subtype":"init","cwd":"/p.arclight","session_id":"s-1","model":"claude-opus-5-5","claude_code_version":"2.1.322","tools":[],"mcp_servers":[],"apiKeySource":"none"}"#
    static let start =
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":12,"cache_creation_input_tokens":3000,"cache_read_input_tokens":40000,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u1","ttft_ms":900}"#
    static let delta =
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":250}},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u2"}"#
    static let stop =
        #"{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null,"session_id":"s-1","uuid":"u3"}"#
    static let result =
        #"{"type":"result","subtype":"success","is_error":false,"duration_ms":15200,"duration_api_ms":9800,"num_turns":2,"result":"Done","stop_reason":"end_turn","session_id":"s-1","total_cost_usd":1.23,"usage":{"input_tokens":20,"cache_creation_input_tokens":3500,"cache_read_input_tokens":82000,"output_tokens":400,"server_tool_use":{"web_search_requests":0}},"modelUsage":{"claude-opus-5-5":{"inputTokens":900,"outputTokens":5000,"cacheReadInputTokens":300000,"cacheCreationInputTokens":20000,"webSearchRequests":1,"costUSD":1.229,"contextWindow":200000,"maxOutputTokens":64000},"claude-haiku-5-5":{"inputTokens":300,"outputTokens":20,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.001,"contextWindow":1000000,"maxOutputTokens":64000}},"model_usage_since_last_result":{"claude-opus-5-5":{"inputTokens":20,"outputTokens":400,"cacheReadInputTokens":82000,"cacheCreationInputTokens":3500,"webSearchRequests":1,"costUSD":0.31,"contextWindow":200000,"maxOutputTokens":64000},"claude-haiku-5-5":{"inputTokens":300,"outputTokens":20,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.001,"contextWindow":1000000,"maxOutputTokens":64000}},"permission_denials":[],"uuid":"u9"}"#

    @Test func eachRequestReportsItsUsageFromTheStream() {
        var p = CLIStreamParser()
        #expect(feed(&p, [Self.initLine]).isEmpty)
        #expect(p.model == "claude-opus-5-5")
        #expect(feed(&p, [Self.start, Self.delta]).isEmpty)
        let out = feed(&p, [Self.stop])
        #expect(
            out == [
                .usage(
                    ChatUsage(
                        scope: .request, model: "claude-opus-5-5",
                        tokens: ChatTokens(input: 12, output: 250, cacheRead: 40000, cacheWrite: 3000)))
            ])
        // Reported once.
        #expect(feed(&p, [Self.stop]).isEmpty)
    }

    @Test func aRequestWithoutItsStopIsReportedWhenTheNextStartsOrTheTurnEnds() {
        var p = CLIStreamParser()
        _ = feed(&p, [Self.initLine, Self.start, Self.delta])
        let next = feed(&p, [Self.start])
        #expect(next.count == 1)
        guard case .usage(let first)? = next.first else { Issue.record("no usage"); return }
        #expect(first.tokens.output == 250)
        let end = feed(&p, [Self.result])
        #expect(end.count == 2)  // the unfinished request, then the turn's account
    }

    @Test func subagentRequestsAreLeftToTheResult() {
        var p = CLIStreamParser()
        let sub = Self.start.replacingOccurrences(of: #""parent_tool_use_id":null"#, with: #""parent_tool_use_id":"t1""#)
        let subStop = Self.stop.replacingOccurrences(
            of: #""parent_tool_use_id":null"#, with: #""parent_tool_use_id":"t1""#)
        #expect(feed(&p, [sub, subStop]).isEmpty)
    }

    @Test func resultGivesTheTurnsOwnTokensCostAndContextWindow() {
        var p = CLIStreamParser()
        _ = feed(&p, [Self.initLine])
        let out = feed(&p, [Self.result])
        guard case .usage(let u)? = out.last else { Issue.record("no usage"); return }
        #expect(u.scope == .turn)
        #expect(u.model == "claude-opus-5-5")
        // model_usage_since_last_result, both models: this turn alone (not modelUsage's session totals).
        #expect(u.tokens == ChatTokens(input: 320, output: 420, cacheRead: 82000, cacheWrite: 3500))
        #expect(u.webSearches == 1)
        #expect(abs((u.cost ?? 0) - 0.311) < 1e-9)
        #expect(u.sessionCost == 1.23)
        #expect(u.requests == 2)
        #expect(u.modelTime == 9.8)
        // The main model's window as the agent sees it (here clamped to 200k), not the price list's 1M.
        #expect(u.contextWindow == 200_000)
    }

    @Test func olderAgentsResultFallsBackToUsageAndTheRunningTotal() {
        // An agent without model_usage_since_last_result: tokens from `usage`, cost from total_cost_usd's growth.
        let old1 =
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":4000,"duration_api_ms":3000,"num_turns":1,"result":"a","session_id":"s","total_cost_usd":0.5,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":50}}"#
        let old2 = old1.replacingOccurrences(of: #""total_cost_usd":0.5"#, with: #""total_cost_usd":0.8"#)
        var p = CLIStreamParser()
        let a = feed(&p, [old1]), b = feed(&p, [old2])
        guard case .usage(let u1)? = a.last, case .usage(let u2)? = b.last else { Issue.record("no usage"); return }
        #expect(u1.cost == nil && u1.sessionCost == 0.5)
        #expect(u1.tokens == ChatTokens(input: 10, output: 50, cacheRead: 1000))

        var t = ChatTranscript()
        t.items.append(ChatItem(id: "m1", kind: .user, text: "one"))
        t.beginTurn(item: "m1", backend: .cli, model: "claude-opus-5-5")
        t.apply(.usage(u1))
        t.endTurn(.done)
        t.items.append(ChatItem(id: "m2", kind: .user, text: "two"))
        t.beginTurn(item: "m2", backend: .cli, model: "claude-opus-5-5")
        t.apply(.usage(u2))
        t.endTurn(.done)
        #expect(t.turns[0].cost == 0.5)
        #expect(abs((t.turns[1].cost ?? 0) - 0.3) < 1e-9)
        #expect(abs((t.totalCost ?? 0) - 0.8) < 1e-9)
    }

    @Test func aResultWithoutUsageReportsNothing() {
        var p = CLIStreamParser()
        #expect(feed(&p, [#"{"type":"result","subtype":"success","is_error":false,"result":"Hi"}"#]).isEmpty)
    }

    @Test func rateLimitEventWithEveryWindow() throws {
        let line =
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1763740800,"rateLimitType":"five_hour","utilization":0.82,"isUsingOverage":false,"surpassedThreshold":0.75,"unifiedWindows":{"five_hour":{"utilization":0.82,"resetsAt":1763740800,"status":"allowed_warning","surpassedThreshold":0.75},"seven_day":{"utilization":0.41,"resetsAt":1764000000,"status":"allowed"}}},"uuid":"u","session_id":"s-1"}"#
        var p = CLIStreamParser()
        let now = Date(timeIntervalSince1970: 1_763_730_000)
        guard case .limits(let l)? = feed(&p, [line], now: now).first else { Issue.record("no limits"); return }
        #expect(l.source == .cli)
        #expect(l.status == .warning)
        #expect(l.limiting == "five_hour")
        #expect(l.usingOverage == false)
        #expect(l.observed == now)
        let five = try #require(l.window("five_hour"))
        #expect(five.used == 0.82)
        #expect(five.resets == Date(timeIntervalSince1970: 1_763_740_800))
        #expect(five.status == .warning)
        #expect(five.label == "5-hour limit")
        #expect(l.window("seven_day")?.used == 0.41)
        #expect(l.headline?.id == "five_hour")
    }

    @Test func rateLimitEventFromAnOlderAgentHasOnlyTheLimitingWindow() throws {
        let line =
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1763740800,"rateLimitType":"seven_day_opus","isUsingOverage":false},"uuid":"u","session_id":"s"}"#
        var p = CLIStreamParser()
        guard case .limits(let l)? = feed(&p, [line]).first else { Issue.record("no limits"); return }
        #expect(l.status == .rejected)
        #expect(l.windows.map(\.id) == ["seven_day_opus"])
        #expect(l.windows.first?.used == nil)
        #expect(l.windows.first?.resets == Date(timeIntervalSince1970: 1_763_740_800))

        // A later report of another window keeps this one.
        let later = try #require(
            ChatLimits(
                cli: ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.1, "resetsAt": 1763700000]))
        let merged = later.merged(onto: l)
        #expect(Set(merged.windows.map(\.id)) == ["seven_day_opus", "five_hour"])
        #expect(merged.status == .allowed)
        // The other backend's report replaces it all.
        let api = ChatLimits(source: .api, windows: [.init(id: "requests", used: 0.5)])
        #expect(api.merged(onto: merged).windows.map(\.id) == ["requests"])
    }
}

@Suite struct ChatUsageAPITests {
    @Test func assemblerReadsUsageFromMessageStartAndDelta() throws {
        var a = MessageAssembler()
        for l in [
            #"{"type":"message_start","message":{"id":"m","model":"claude-sonnet-5-5","usage":{"input_tokens":5,"cache_creation_input_tokens":1200,"cache_read_input_tokens":30000,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42,"server_tool_use":{"web_search_requests":2}}}"#,
            #"{"type":"message_stop"}"#,
        ] { _ = try a.feed(Data(l.utf8)) }
        #expect(a.message.usage == ChatTokens(input: 5, output: 42, cacheRead: 30000, cacheWrite: 1200))
        #expect(a.message.model == "claude-sonnet-5-5")
        #expect(a.message.webSearches == 2)
        #expect(a.message.content.count == 1)
    }

    @Test func aStreamWithoutUsageHasNone() throws {
        var a = MessageAssembler()
        _ = try a.feed(Data(#"{"type":"message_stop"}"#.utf8))
        #expect(a.message.usage == nil)
    }

    @Test func pricesFromTheList() {
        let t = ChatTokens(input: 1000, output: 2000, cacheRead: 100_000, cacheWrite: 4000)
        // (1000×4 + 2000×20 + 100000×0.20 + 4000×5) / 1M
        #expect(abs((ChatPricing.cost("claude-opus-5-5", tokens: t) ?? 0) - 0.084) < 1e-9)
        #expect(abs((ChatPricing.cost("claude-opus-5-5[1m]", tokens: t, webSearches: 3) ?? 0) - 0.114) < 1e-9)
        // Haiku costs more once the prompt passes 100K.
        #expect(ChatPricing.price("claude-haiku-5-5", prompt: 50_000)?.input == 0.10)
        #expect(ChatPricing.price("claude-haiku-5-5", prompt: 150_000)?.input == 0.50)
        #expect(ChatPricing.cost("claude-opus-4-8", tokens: t) == nil)
        #expect(ChatPricing.contextWindow("claude-sonnet-5-5") == 1_000_000)
    }

    @Test func backendReportsEachRequestWithItsCost() async throws {
        var first = StreamedMessage()
        first.content = [["type": "tool_use", "id": "t1", "name": "scene_get", "input": [:]]]
        first.stopReason = "tool_use"
        first.usage = ChatTokens(input: 10, output: 100, cacheRead: 0, cacheWrite: 5000)
        first.model = "claude-opus-5-5"
        var second = StreamedMessage()
        second.content = [["type": "text", "text": "Done"]]
        second.stopReason = "end_turn"
        second.usage = ChatTokens(input: 20, output: 30, cacheRead: 5100, cacheWrite: 0)
        // A fallback model with no listed price: priced as the one asked for.
        second.model = "claude-opus-4-8"
        let b = APIChatBackend(
            client: UsageStream([first, second]), runner: NoTools(), model: .opus, effort: .medium,
            projectPath: "/p.arclight", history: [])
        let ev = Collected()
        try await b.send("go", context: nil, onEvent: { ev.add($0) })
        let u = ev.usage
        #expect(u.count == 2)
        #expect(u.allSatisfy { $0.scope == .request })
        #expect(u[0].model == "claude-opus-5-5" && u[0].contextWindow == 1_000_000)
        let firstCost = 0.02704  // (10×4 + 100×20 + 5000×5) / 1M
        let secondCost = 0.0017  // (20×4 + 30×20 + 5100×0.20) / 1M, at Opus 5.5's prices
        #expect(abs((u[0].cost ?? 0) - firstCost) < 1e-12)
        #expect(u[1].model == "claude-opus-4-8")
        #expect(abs((u[1].cost ?? 0) - secondCost) < 1e-12)
        #expect(u.allSatisfy { ($0.modelTime ?? -1) >= 0 })
        // Usage comes after the request's own events, before the tool it asked for runs.
        let order = ev.all.map { e -> String in
            switch e {
            case .usage: return "usage"
            case .toolStart: return "start"
            default: return "-"
            }
        }.filter { $0 != "-" }
        #expect(order == ["usage", "start", "usage"])
    }

    @Test func rateLimitHeaders() throws {
        let h = [
            "Anthropic-Ratelimit-Requests-Limit": "50", "anthropic-ratelimit-requests-remaining": "49",
            "anthropic-ratelimit-requests-reset": "2026-11-21T10:00:30Z",
            "anthropic-ratelimit-input-tokens-limit": "400000",
            "anthropic-ratelimit-input-tokens-remaining": "100000",
            "anthropic-ratelimit-input-tokens-reset": "2026-11-21T10:00:12.500Z",
            "content-type": "text/event-stream",
        ]
        let l = try #require(ChatLimits(apiHeaders: h))
        #expect(l.source == .api && l.status == .allowed)
        let r = try #require(l.window("requests"))
        #expect(r.limit == 50 && r.remaining == 49)
        #expect(abs((r.used ?? 0) - 0.02) < 1e-9)
        #expect(r.resets == ISO8601DateFormatter().date(from: "2026-11-21T10:00:30Z"))
        let input = try #require(l.window("input_tokens"))
        #expect(input.used == 0.75)
        #expect(input.resets != nil)
        #expect(l.headline?.id == "input_tokens")
        #expect(ChatLimits(apiHeaders: h, httpStatus: 429)?.status == .rejected)
        #expect(ChatLimits(apiHeaders: ["content-type": "application/json"]) == nil)
    }
}

@Suite struct ChatUsageTranscriptTests {
    @Test func turnsAddUpRequestsToolsTimeAndContext() throws {
        var t = ChatTranscript()
        let t0 = Date(timeIntervalSince1970: 1000)
        t.items.append(ChatItem(id: "m1", kind: .user, text: "make it red", created: t0))
        t.beginTurn(item: "m1", backend: .api, model: "claude-opus-5-5", now: t0)
        #expect(t.currentTurn?.item == "m1")
        t.apply(.thinking("hm"), now: t0.addingTimeInterval(1))
        t.apply(
            .usage(
                ChatUsage(
                    scope: .request, model: "claude-opus-5-5", tokens: ChatTokens(input: 10, output: 100, cacheWrite: 5000),
                    cost: 0.03, modelTime: 2, contextWindow: 1_000_000)), now: t0.addingTimeInterval(2))
        t.apply(.toolStart(id: "c1", name: "scene_get", input: "{}"), now: t0.addingTimeInterval(3))
        t.apply(.toolEnd(id: "c1", ok: true, summary: "ok", image: nil), now: t0.addingTimeInterval(4.5))
        t.apply(
            .usage(
                ChatUsage(
                    scope: .request, model: "claude-opus-5-5", tokens: ChatTokens(input: 20, output: 30, cacheRead: 5100),
                    cost: 0.002, modelTime: 1.5)), now: t0.addingTimeInterval(6))
        t.apply(.text("Done"), now: t0.addingTimeInterval(6))
        #expect(t.currentTurn?.running == true)
        t.endTurn(.done, now: t0.addingTimeInterval(7))
        #expect(t.currentTurn == nil)

        let turn = try #require(t.turn(for: "m1"))
        #expect(turn.duration == 7)
        #expect(turn.outcome == .done)
        #expect(turn.requests == 2)
        #expect(turn.tools == 1)
        #expect(turn.tokens == ChatTokens(input: 30, output: 130, cacheRead: 5100, cacheWrite: 5000))
        #expect(abs((turn.cost ?? 0) - 0.032) < 1e-12)
        #expect(turn.modelTime == 3.5)
        #expect(turn.context == 5120)  // the last request's prompt

        // Rows carry when they appeared; a tool row how long it ran.
        #expect(t.items.map(\.created) == [0, 1, 3, 6].map { Optional(t0.addingTimeInterval($0)) })
        #expect(t.items[2].duration == 1.5)

        let ctx = try #require(t.context)
        #expect(ctx.used == 5120 && ctx.window == 1_000_000)
        #expect(abs((ctx.fraction ?? 0) - 0.00512) < 1e-12)

        // A second turn (answering a choice card) adds to the totals.
        t.beginTurn(item: "card", backend: .api, model: "claude-opus-5-5", now: t0.addingTimeInterval(10))
        t.apply(
            .usage(ChatUsage(scope: .request, tokens: ChatTokens(input: 1, output: 2, cacheRead: 10000), cost: 0.01)),
            now: t0.addingTimeInterval(11))
        t.endTurn(.stopped, now: t0.addingTimeInterval(12))
        #expect(t.turns.count == 2)
        #expect(t.turns[1].outcome == .stopped)
        #expect(t.totalTokens == ChatTokens(input: 31, output: 132, cacheRead: 15100, cacheWrite: 5000))
        #expect(abs((t.totalCost ?? 0) - 0.042) < 1e-12)
        #expect(t.context?.used == 10001)
        // The window carries over from an earlier report for the same model.
        #expect(t.context?.window == 1_000_000)
    }

    @Test func theAgentsTurnAccountReplacesTheSummedRequests() {
        var t = ChatTranscript()
        t.beginTurn(item: nil, backend: .cli, model: "claude-opus-5-5")
        t.apply(.usage(ChatUsage(scope: .request, tokens: ChatTokens(input: 5, output: 50, cacheRead: 40000))))
        t.apply(.usage(ChatUsage(scope: .request, tokens: ChatTokens(input: 6, output: 60, cacheRead: 41000))))
        #expect(t.turns[0].requests == 2 && t.turns[0].cost == nil)
        t.apply(
            .usage(
                ChatUsage(
                    scope: .turn, model: "claude-opus-5-5", tokens: ChatTokens(input: 11, output: 110, cacheRead: 81000),
                    cost: 0.2, requests: 2, modelTime: 4, contextWindow: 200_000, sessionCost: 0.9)))
        let turn = t.turns[0]
        #expect(turn.tokens == ChatTokens(input: 11, output: 110, cacheRead: 81000))
        #expect(turn.cost == 0.2 && turn.sessionCost == 0.9)
        #expect(turn.context == 41006)  // from the last request; the turn's sum isn't a context size
        #expect(t.context?.window == 200_000)

        // A zeroed account (a run that failed to start) doesn't wipe what the requests added up to.
        t.apply(.usage(ChatUsage(scope: .turn, tokens: ChatTokens(), requests: 0)))
        #expect(t.turns[0].tokens.output == 110 && t.turns[0].requests == 2)
    }

    @Test func usageWithoutABegunTurnOpensOne() {
        var t = ChatTranscript()
        t.items.append(ChatItem(id: "m", kind: .user, text: "hi"))
        t.apply(.usage(ChatUsage(scope: .request, tokens: ChatTokens(input: 1, output: 1))))
        #expect(t.turns.count == 1 && t.turns[0].item == "m" && t.turns[0].running)
        // Limits aren't the transcript's.
        t.apply(.limits(ChatLimits(source: .cli, windows: [])))
        #expect(t.turns.count == 1 && t.items.count == 1)
    }

    @Test func aTurnLeftRunningEndsWhenTheChatWasLastSaved() {
        var t = ChatTranscript()
        let t0 = Date(timeIntervalSince1970: 500)
        t.beginTurn(item: nil, backend: .cli, model: "claude-opus-5-5", now: t0)
        t.updated = t0.addingTimeInterval(30)
        t.closeAbandonedTurn()
        #expect(t.turns[0].duration == 30 && t.turns[0].outcome == .stopped)
    }

    @Test func oldTranscriptsStillLoad() throws {
        // Saved before rows had times and turns were recorded.
        let json = #"""
            {"items":[{"id":"a","kind":"user","text":"hi","checkpoint":{"s":2},"historyCount":0},
            {"id":"b","kind":"thinking","text":"hm","started":700000000,"duration":2},
            {"id":"c","kind":"assistant","text":"Hello"}],
            "history":[],"cliSession":"s-1","id":"x","created":700000000}
            """#
        let t = try JSONDecoder().decode(ChatTranscript.self, from: Data(json.utf8))
        #expect(t.items.count == 3)
        #expect(t.items.allSatisfy { $0.created == nil })
        #expect(t.items[1].duration == 2)
        #expect(t.turns.isEmpty)
        #expect(t.totalTokens.isEmpty && t.totalCost == nil && t.context == nil)

        // Turns that don't read (from some later version) don't stop the chat from opening.
        let odd = json.replacingOccurrences(of: #""id":"x""#, with: #""id":"x","turns":"nope""#)
        #expect(try JSONDecoder().decode(ChatTranscript.self, from: Data(odd.utf8)).items.count == 3)
    }

    @Test func turnsAndTimesSurviveASave() throws {
        var t = ChatTranscript()
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        t.created = t0
        t.items.append(ChatItem(kind: .user, text: "hi", created: t0))
        t.beginTurn(item: t.items[0].id, backend: .api, model: "claude-haiku-5-5", now: t0)
        t.apply(
            .usage(ChatUsage(scope: .request, tokens: ChatTokens(input: 3, output: 4), cost: 0.0001)),
            now: t0.addingTimeInterval(1))
        t.endTurn(.done, now: t0.addingTimeInterval(2))
        let back = try JSONDecoder().decode(ChatTranscript.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        #expect(back.items[0].created != nil)
        // A turn written with fewer fields reads with defaults.
        let thin = try JSONDecoder().decode(ChatTurn.self, from: Data(#"{"started":10}"#.utf8))
        #expect(thin.tokens.isEmpty && thin.requests == 0 && thin.finished == nil)
    }
}
