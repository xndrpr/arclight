import AVFoundation
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor
@testable import ArclightMCP

/// Serves a tiny Openverse: one search answer, one item and its mp3-less WAV file.
final class OpenverseMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let u = request.url!
        OpenverseMock.requests.append(u.path + (u.query.map { "?" + $0 } ?? ""))
        let body = OpenverseMock.files[u.path]
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: u, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Stands in for fal.ai audio: returns a short WAV and remembers the request.
final class FakeAudio: AudioProvider, @unchecked Sendable {
    var requests: [AudioAI.Request] = []
    let wav: Data
    init(wav: Data) { self.wav = wav }
    func audio(_ r: AudioAI.Request) async throws -> GeneratedAudio {
        requests.append(r)
        return GeneratedAudio(data: wav, model: AudioCatalog.models(r.kind)[0].id)
    }
}

/// Runs blocking work (MCP tools and the exporter wait on async work with semaphores) on its own thread, so it
/// never holds one of Swift Testing's cooperative threads while the work it waits for needs one.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try work() }) }.start()
    }
}

@Suite(.serialized) struct AudioAITests {
    static func wavData(seconds: Double = 0.5) throws -> Data {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: u) }
        try AudioFiles.writeWAV(SoundSynth.render(.pop, duration: seconds), sampleRate: 48000, to: u)
        return try Data(contentsOf: u)
    }

    static func run(_ server: MCPServer, _ name: String, _ a: [String: JSONValue]) throws -> String {
        guard let tool = server.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return try tool.run(a).compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
    }

    // MARK: Model

    @Test func soundOpsAddMergeAndRemoveClips() throws {
        var s = Scene(id: "s", duration: 4)
        s = try SceneOps.apply(
            [
                ["op": "sound", "src": "whoosh.wav", "offset": 2],
                ["op": "sound", "src": "whoosh.wav", "offset": 0.5, "gain": 0.7],
                ["op": "sound", "id": "pop", "src": "pop.wav", "offset": 1],
            ], to: s
        ).scene
        #expect(s.sounds?.map(\.id) == ["whoosh-2", "pop", "whoosh"])  // sorted by time
        s = try SceneOps.apply([["op": "sound", "id": "pop", "gain": 0.5, "mute": true, "offset": .null]], to: s).scene
        let pop = try #require(s.sound("pop"))
        #expect(pop.gain == 0.5 && pop.mute == true && pop.offset == nil && pop.src == "pop.wav")
        #expect(s.audibleClips.map(\.id) == ["whoosh-2", "whoosh"])
        #expect(Outline.scene(s, project: Project(name: "p")).contains("sounds: pop=pop.wav@0 gain 0.5 (muted)"))
        #expect(throws: (any Error).self) { try SceneOps.apply([["op": "sound", "id": "nope", "gain": 1]], to: s) }
        #expect(throws: (any Error).self) { try SceneOps.apply([["op": "sound", "id": "pop", "gain": 9]], to: s) }
        s = try SceneOps.apply([["op": "sound", "id": "pop", "remove": true]], to: s).scene
        #expect(s.sounds?.count == 2)
        s = try SceneOps.apply([["op": "scene", "sounds": .array([])]], to: s).scene
        #expect(s.sounds == nil)
        // Round trip through JSON, and an old scene without sounds still decodes.
        var withSound = s
        withSound.sounds = [{ var r = AudioRef(src: "a.wav"); r.id = "a"; r.length = 0.4; return r }()]
        let back = try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(withSound))
        #expect(back.sounds?.first?.length == 0.4)
        #expect(Schema.checkScene(back).isEmpty)
        var dup = back
        dup.sounds! += dup.sounds!
        #expect(Schema.checkScene(dup).contains("sounds: duplicate id 'a'"))
    }

    @Test func placementAndClipAgreeOnLengthAndFadeOut() {
        var a = AudioRef(src: "x.wav"); a.offset = 1; a.trim = 0.5; a.length = 1; a.fadeOut = 0.5
        let p = SceneAudio.placement(a, fileDuration: 4, sceneDuration: 5)
        #expect(p == .init(fileStart: 0.5, at: 1, length: 1))
        let c = AudioClip(a, fileDuration: 4, sceneDuration: 5)
        #expect(c.end == 2 && c.audibleEnd == 2)
        // The fade ends where the clip stops, not at the scene end.
        #expect(abs(c.envelope(at: 1.75) - 0.5) < 1e-9 && c.envelope(at: 1.2) == 1 && c.envelope(at: 2) == 0)
        var b = AudioRef(src: "x.wav"); b.offset = -1
        #expect(SceneAudio.placement(b, fileDuration: 4, sceneDuration: 2) == .init(fileStart: 1, at: 0, length: 2))
        b.offset = 3
        #expect(SceneAudio.placement(b, fileDuration: 4, sceneDuration: 3) == nil)
    }

    // MARK: Synth, files, analysis

    @Test func synthPresetsAreAudibleBoundedAndRepeatable() throws {
        for p in SoundSynth.Preset.allCases {
            let s = SoundSynth.render(p)
            #expect(s.count == Int(p.defaultDuration * SoundSynth.sampleRate), "\(p)")
            let peak = s.reduce(Float(0)) { max($0, abs($1)) }
            #expect(peak > 0.5 && peak <= 0.9, "\(p) peak \(peak)")
            #expect(s.allSatisfy { $0.isFinite }, "\(p)")
            #expect(abs(s.first!) < 0.01 && abs(s.last!) < 0.01, "\(p) starts and ends quietly")
        }
        #expect(SoundSynth.render(.whoosh, seed: 3) == SoundSynth.render(.whoosh, seed: 3))
        #expect(SoundSynth.render(.whoosh, seed: 3) != SoundSynth.render(.whoosh, seed: 4))
        let tp = try TempProject("synth")
        defer { tp.remove() }
        let name = try SoundSynth.write(.riser, duration: 1.5, pitch: 2, seed: 1, name: nil, store: tp.store)
        #expect(name == "riser.wav")
        let info = try #require(SceneAudio.info(tp.store.assetsURL.appendingPathComponent(name)))
        #expect(abs(info.duration - 1.5) < 0.01)
        #expect(try SoundSynth.write(.riser, duration: nil, pitch: 0, seed: 1, name: nil, store: tp.store) == "riser-2.wav")
    }

    @Test func audioFilesSniffAndRefuseWhatCantPlay() throws {
        #expect(AudioFiles.sniff(Data("RIFF\0\0\0\0WAVEfmt ".utf8)) == "wav")
        #expect(AudioFiles.sniff(Data("ID3\u{3}".utf8)) == "mp3")
        #expect(AudioFiles.sniff(Data([0xFF, 0xFB, 0x90, 0])) == "mp3")
        #expect(AudioFiles.sniff(Data("OggS\0".utf8)) == nil)
        let tp = try TempProject("sniff")
        defer { tp.remove() }
        #expect(throws: (any Error).self) { try AudioFiles.write(Data("OggS....".utf8), base: "x", store: tp.store) }
        #expect(try AudioFiles.write(try Self.wavData(), base: "pop", store: tp.store) == "pop.wav")
        AudioFiles.credit(tp.store, asset: "pop.wav", line: "“Pop” by Someone, CC BY 4.0")
        AudioFiles.credit(tp.store, asset: "pop.wav", line: "“Pop” by Someone, CC BY 4.0")
        let credits = try String(contentsOf: tp.store.assetsURL.appendingPathComponent("CREDITS.md"), encoding: .utf8)
        #expect(credits.components(separatedBy: "pop.wav").count == 2)  // written once
    }

    @Test func analysisFindsTempoBeatsAndPhrases() {
        // Clicks at 120 BPM for 8 s.
        let sr = 22050.0
        var x = [Float](repeating: 0, count: Int(8 * sr))
        for b in 0..<16 {
            let at = Int((0.25 + Double(b) * 0.5) * sr)
            for i in 0..<400 where at + i < x.count { x[at + i] = Float(sin(Double(i) * 0.9) * exp(-Double(i) / 80)) }
        }
        let r = AudioAnalysis.analyze(samples: x, sampleRate: sr)
        #expect(r.bpm.map { abs($0 - 120) < 3 } == true, "bpm \(String(describing: r.bpm))")
        #expect(r.onsets.count >= 14 && r.onsets.count <= 17, "onsets \(r.onsets)")
        #expect(r.beats.contains { abs($0 - 2.25) < 0.04 }, "beats \(r.beats)")
        // Two "sentences" of tone with a pause between: two phrases, no tempo.
        var v = [Float](repeating: 0, count: Int(4 * sr))
        for i in 0..<v.count {
            let t = Double(i) / sr
            if (0.2..<1.4).contains(t) || (2.1..<3.6).contains(t) { v[i] = Float(sin(t * 2 * .pi * 220) * 0.5) }
        }
        let p = AudioAnalysis.analyze(samples: v, sampleRate: sr)
        #expect(p.phrases.count == 2, "\(p.phrases)")
        #expect(abs((p.phrases.first?.lowerBound ?? 0) - 0.2) < 0.03 && abs((p.phrases.last?.upperBound ?? 0) - 3.6) < 0.03)
        #expect(p.bpm == nil)
        #expect(p.summary.contains("phrases between pauses (2)"))
    }

    @Test func speechVoiceListingAndPicking() {
        let vs = Speech.parse(
            "Albert              en_US    # Hello!\nMilena              ru_RU    # Привет!\nEddy (English (US)) en_US    # Hi\nSamantha            en_US    # Hi\n")
        #expect(vs.map(\.name) == ["Albert", "Milena", "Eddy (English (US))", "Samantha"])
        #expect(Speech.pick(nil, text: "Привет, мир", from: vs)?.name == "Milena")
        #expect(Speech.pick(nil, text: "Hello world", from: vs)?.name == "Samantha")
        #expect(Speech.pick("eddy", text: "x", from: vs)?.name == "Eddy (English (US))")
    }

    // MARK: fal request shapes

    @Test func falAudioRequestsFollowEachModel() {
        var r = AudioAI.Request(kind: .sfx, prompt: "door creak")
        r.duration = 40; r.loop = true
        let sfx = AudioCatalog.input(model: "elevenlabs/sound-effects/v3", r)
        #expect(sfx["text"] == "door creak" && sfx["duration_seconds"] == 30 && sfx["loop"] == true)
        #expect(AudioCatalog.input(model: "fal-ai/elevenlabs/sound-effects/v2", r)["duration_seconds"] == 22)
        var m = AudioAI.Request(kind: .music, prompt: "lofi")
        m.duration = 12
        #expect(AudioCatalog.input(model: "fal-ai/elevenlabs/music", m)["music_length_ms"] == 12000)
        #expect(AudioCatalog.input(model: "fal-ai/stable-audio-25/text-to-audio", m)["seconds_total"] == 12)
        var v = AudioAI.Request(kind: .voice, prompt: "Привет")
        v.voice = "Aria"; v.speed = 2; v.language = "ru"
        let tts = AudioCatalog.input(model: "fal-ai/elevenlabs/tts/multilingual-v2", v)
        #expect(tts["voice"] == "Aria" && tts["speed"] == 1.2 && tts["language_code"] == "ru")
        #expect(AudioCatalog.audioURL(in: ["audio": ["url": "https://x/a.mp3"]]) == "https://x/a.mp3")
        #expect(AudioCatalog.audioURL(in: ["audio": "https://x/b.wav"]) == "https://x/b.wav")
    }

    // MARK: MCP tools

    @Test func toolsSearchImportSynthGenerateAndAnalyze() async throws {
        try await offPool { try Self.toolsScenario() }
    }

    static func toolsScenario() throws {
        let tp = try TempProject("audio-mcp", scenes: [Scene(id: "s", duration: 6)])
        defer { tp.remove() }
        let wav = try Self.wavData()
        OpenverseMock.requests = []
        let item: JSONValue = [
            "id": "abc-123", "title": "Big Whoosh", "creator": "Kino", "duration": 800, "license": "by",
            "license_version": "4.0", "source": "freesound", "foreign_landing_url": "https://freesound.org/s/1",
            "url": "https://files.test/whoosh.wav", "filetype": "wav", "tags": [["name": "whoosh"]],
        ]
        let ogg: JSONValue = ["id": "ogg-1", "title": "Ogg only", "license": "cc0", "url": "https://files.test/a.ogg", "filetype": "ogg"]
        let long: JSONValue = ["id": "long-1", "title": "Long", "license": "cc0", "duration": 90000, "url": "https://files.test/l.mp3", "filetype": "mp3"]
        OpenverseMock.files = [
            "/v1/audio": try JSONEncoder().encode(JSONValue.object(["results": [ogg, long, item]])),
            "/v1/audio/abc-123": try JSONEncoder().encode(item),
            "/whoosh.wav": wav,
        ]
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [OpenverseMock.self]
        let server = MCPServer(projectPath: tp.url.path)
        server.soundLibraryOverride = SoundLibrary(
            session: URLSession(configuration: c), api: URL(string: "https://api.test/v1")!)
        let fake = FakeAudio(wav: wav)
        server.audioProviderOverride = fake

        let found = try run(server, "sound_search", ["query": "whoosh", "kind": "sfx", "max_seconds": 10])
        #expect(found.contains("abc-123 — Big Whoosh") && found.contains("credit needed"))
        #expect(!found.contains("ogg-1") && !found.contains("long-1"))  // unplayable format, too long
        #expect(OpenverseMock.requests.first?.contains("source=freesound") == true)
        #expect(OpenverseMock.requests.first?.contains("license_type=commercial,modification") == true)

        let imported = try run(server, "sound_import", ["sound": "abc-123", "scene": "s", "at": 1.2, "gain": 0.7])
        #expect(imported.contains("asset big-whoosh.wav") && imported.contains("sound big-whoosh at 1.2s"))
        let credits = try String(contentsOf: tp.store.assetsURL.appendingPathComponent("CREDITS.md"), encoding: .utf8)
        #expect(credits.contains("big-whoosh.wav") && credits.contains("Kino"))

        _ = try run(server, "sound_synth", ["preset": "impact", "scene": "s", "at": 3, "id": "land"])
        _ = try run(server, "sound_generate", ["kind": "music", "prompt": "uplifting pop", "scene": "s"])
        #expect(fake.requests.last?.kind == .music && fake.requests.last?.duration == 6)  // fills the scene
        try tp.store.reload()
        let s = try tp.store.scene("s")
        #expect(s.sounds?.map(\.id) == ["big-whoosh", "land"])
        #expect(s.sound("big-whoosh")?.gain == 0.7 && s.sound("land")?.offset == 3)
        #expect(s.audio?.src == "uplifting-pop.wav")

        let heard = try run(server, "audio_analyze", ["scene": "s", "sound": "land", "markers": "onsets"])
        #expect(heard.contains("times are scene times") && heard.contains("wrote"))
        try tp.store.reload()
        let marked = try tp.store.scene("s").markers ?? []
        #expect(marked.first?.name == "hit-1" && abs((marked.first?.t ?? 0) - 3) < 0.05)

        #expect(throws: (any Error).self) { try run(server, "sound_synth", ["preset": "kazoo"]) }
        #expect(throws: (any Error).self) { try run(server, "sound_import", ["sound": "../etc"]) }
    }

    @Test(.requiresMetal) func exportMixesSoundsWithTheAudio() async throws {
        try await offPool { try Self.exportScenario() }
    }

    static func exportScenario() throws {
        let tp = try TempProject("mix")
        defer { tp.remove() }
        let dir = tp.store.assetsURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AudioFiles.writeWAV(SoundSynth.render(.impact, duration: 0.5), sampleRate: 48000, to: dir.appendingPathComponent("hit.wav"))
        var s = Scene(id: "s", duration: 1.5)
        s.nodes = [Node(id: "r", type: "shape", props: ["width": .value(40), "height": .value(40)])]
        var hit = AudioRef(src: "hit.wav"); hit.id = "hit"; hit.offset = 0.6
        s.sounds = [hit]
        let out = tp.url.appendingPathComponent("s.mp4")
        _ = try Exporter(renderer: try Renderer()).export(
            scene: s, project: Project(name: "p", size: [160, 90]), assets: dir, to: out, options: ExportOptions())
        let asset = AVURLAsset(url: out)
        let tracks = try SceneAudio.sync { try await asset.loadTracks(withMediaType: .audio).count }
        #expect(tracks == 1)
        // A sound wholly past the scene end: nothing audible, the video is kept without audio.
        s.sounds![0].offset = 5
        _ = try Exporter(renderer: try Renderer()).export(
            scene: s, project: Project(name: "p", size: [160, 90]), assets: dir, to: out, options: ExportOptions())
        let none = try SceneAudio.sync { try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).count }
        #expect(none == 0)
    }
}
