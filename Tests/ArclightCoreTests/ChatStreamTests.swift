import Foundation
import Testing

@testable import ArclightCore

@Suite struct ChatStreamTests {
    private func feed(_ lines: [String]) throws -> (MessageAssembler, [ChatEvent]) {
        var a = MessageAssembler()
        var events: [ChatEvent] = []
        for l in lines { if let e = try a.feed(Data(l.utf8)) { events.append(e) } }
        return (a, events)
    }

    @Test func assemblesThinkingTextAndSplitToolInput() throws {
        let (a, events) = try feed([
            #"{"type":"message_start","message":{"id":"m"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"On it"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"scene_get","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"sce"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ne\":\"a\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(a.done)
        #expect(events == [.thinking("Let me"), .text("On it")])
        let m = a.message
        #expect(m.stopReason == "tool_use")
        #expect(m.content.count == 3)
        #expect(m.content[0]["signature"]?.string == "SIG")
        #expect(m.content[1]["text"]?.string == "On it")
        #expect(m.content[2]["input"] == ["scene": "a"])
        #expect(m.invalidToolInputs.isEmpty)
    }

    @Test func cutOffToolInputIsMarkedInvalid() throws {
        let (a, _) = try feed([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"x","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"scene\": \"a"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(a.message.stopReason == "max_tokens")
        #expect(a.message.invalidToolInputs == ["t1"])
        #expect(a.message.content.first?["input"] == [:])
    }

    @Test func refusalDetailsAndStreamErrors() throws {
        let (a, _) = try feed([
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"bio"}}}"#,
            #"{"type":"message_stop"}"#,
        ])
        #expect(a.message.stopDetails?["category"]?.string == "bio")
        #expect(throws: ChatAPIError.stream("Overloaded")) {
            _ = try feed([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        }
    }

    @Test func cliStreamParserReadsDeltasToolsAndResult() {
        var p = CLIStreamParser()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-1"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__arclight__scene_get","input":{"scene":"a"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"ok"}]}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hi"}"#,
        ]
        let events = lines.flatMap { p.feed(Data($0.utf8)) }
        #expect(p.sessionId == "s-1")
        #expect(p.error == nil)
        #expect(
            events == [
                .text("Hi"), .toolStart(id: "t1", name: "scene_get", input: #"{"scene":"a"}"#),
                .toolEnd(id: "t1", ok: true, summary: "ok", image: nil),
            ])
        var bad = CLIStreamParser()
        _ = bad.feed(Data(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#.utf8))
        #expect(bad.error == "the agent stopped: error_during_execution")
    }

    @Test func cliAskChoiceBecomesACardOnceTheServerAcceptsIt() {
        var p = CLIStreamParser()
        let call =
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__arclight__ask_choice","input":{"stage":"look","question":"Which?","options":[{"id":"A","title":"Warm","visual":{"scene":"look-a","time":0.5}}]}}]}}"#
        #expect(p.feed(Data(call.utf8)).isEmpty)
        let ok = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Shown"}]}}"#
        guard case .choice(let c)? = p.feed(Data(ok.utf8)).first else {
            Issue.record("expected a choice")
            return
        }
        #expect(c.id == "t1" && c.stage == .look && c.options.first?.visual?.scene == "look-a")

        var q = CLIStreamParser()
        _ = q.feed(Data(call.replacingOccurrences(of: "t1", with: "t2").utf8))
        let bad =
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ask_choice: nope","is_error":true}]}}"#
        let events = q.feed(Data(bad.utf8))
        #expect(events.count == 2)
        #expect(events.last == .toolEnd(id: "t2", ok: false, summary: "ask_choice: nope", image: nil))
    }

    @Test func cliArgumentsAttachOnlyArclightTools() {
        let b = CLIChatBackend(
            executable: URL(fileURLWithPath: "/bin/echo"), model: .sonnet, projectPath: "/p.arclight",
            serverCommand: "/Apps/arclight", session: nil)
        let first = b.arguments(resume: nil, newSession: "u-1")
        #expect(first.contains("--strict-mcp-config"))
        #expect(first[first.firstIndex(of: "--tools")! + 1] == "")
        #expect(first[first.firstIndex(of: "--allowedTools")! + 1] == "mcp__arclight__*")
        #expect(first.suffix(2) == ["--session-id", "u-1"])
        #expect(
            first[first.firstIndex(of: "--mcp-config")! + 1].contains(
                #""args":["mcp","--project","/p.arclight","--chat"]"#))
        #expect(b.arguments(resume: "u-1", newSession: "x").suffix(2) == ["--resume", "u-1"])
    }

    @Test func transcriptFoldsEventsIntoRows() {
        var t = ChatTranscript()
        t.items.append(ChatItem(kind: .user, text: "hi"))
        for e: ChatEvent in [
            .thinking("a"), .thinking("b"), .text("He"), .text("llo"),
            .toolStart(id: "t", name: "scene_get", input: "{}"), .toolEnd(id: "t", ok: true, summary: "s", image: nil),
            .text("Done"),
        ] { t.apply(e) }
        #expect(t.items.map(\.kind) == [.user, .thinking, .assistant, .tool, .assistant])
        #expect(t.items[1].text == "ab")
        #expect(t.items[2].text == "Hello")
        #expect(t.items[3].ok == true)
    }

    @Test func chatKeyAndSettingsDefaults() throws {
        let saved = KeychainStore.backend
        defer { KeychainStore.backend = saved }
        let mem = KeychainStore.MemoryBackend()
        KeychainStore.backend = mem
        #expect(KeychainStore.chatKey(environment: [:]) == nil)
        try KeychainStore.setChatKey(" sk-test ")
        #expect(KeychainStore.chatKey(environment: [:]) == "sk-test")
        #expect(KeychainStore.chatKey(environment: ["ANTHROPIC_API_KEY": "env"]) == "env")
        #expect(KeychainStore.falKey(environment: [:]) == nil)  // separate accounts
        try KeychainStore.setChatKey(nil)
        #expect(mem.values["anthropic"] == nil)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir); ChatSettings.overrideURL = nil }
        ChatSettings.overrideURL = dir.appendingPathComponent("s.json")
        #expect(ChatSettings.model == .opus)
        #expect(ChatSettings.effort == .medium)
        let d = try #require(UserDefaults(suiteName: dir.appendingPathComponent("d").path))
        #expect(!ChatSettings.cliAllowed(defaults: d, environment: [:]))
        #expect(ChatSettings.cliAllowed(defaults: d, environment: ["ARCLIGHT_EXPERIMENTAL_CLI_CHAT": "1"]))
        d.set(true, forKey: ChatSettings.cliFlagKey)
        #expect(ChatSettings.cliAllowed(defaults: d, environment: [:]))
    }
}
