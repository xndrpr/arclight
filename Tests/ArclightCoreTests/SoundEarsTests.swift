import AVFoundation
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite(.serialized) struct SoundEarsTests {
    /// A sine in both channels at 48 kHz.
    private func sine(_ hz: Double, amp: Double, seconds: Double, env: (Double) -> Double = { _ in 1 }) -> Stereo {
        let n = Int(seconds * Stereo.rate)
        let x = (0..<n).map { i -> Float in
            let t = Double(i) / Stereo.rate
            return Float(sin(2 * .pi * hz * t) * amp * env(t))
        }
        return Stereo(l: x, r: x)
    }

    private func write(_ s: Stereo, to url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Stereo.rate, channels: 2)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        buf.frameLength = AVAudioFrameCount(s.count)
        for i in 0..<s.count { buf.floatChannelData![0][i] = s.l[i]; buf.floatChannelData![1][i] = s.r[i] }
        try f.write(from: buf)
    }

    @Test func loudnessMatchesTheBroadcastMeter() {
        // BS.1770: a 1 kHz sine at −20 dBFS in both channels reads −20 LUFS.
        let s = sine(1000, amp: 0.1, seconds: 3)
        let k = Loudness.kWeighted(s)
        #expect(abs(Loudness.integrated(k) - -20) < 0.3)
        #expect(abs(Loudness.level(k) - -20) < 0.3)
        // Half the amplitude is 6 dB quieter; silence in the file is gated out.
        var gapped = sine(1000, amp: 0.05, seconds: 3)
        gapped.l += [Float](repeating: 0, count: 96000); gapped.r += [Float](repeating: 0, count: 96000)
        #expect(abs(Loudness.integrated(Loudness.kWeighted(gapped)) - -26) < 0.4)
        // Low frequencies count for less.
        #expect(Loudness.level(Loudness.kWeighted(sine(50, amp: 0.1, seconds: 2))) < -23)
        // True peak of a sine sampled off its crests is still its amplitude.
        let tp = Loudness.truePeak(sine(11025, amp: 0.5, seconds: 0.5))
        #expect(abs(tp.db - -6.02) < 0.3)
    }

    @Test func descriptorsTellDarkFromBrightAndSharpFromSoft() {
        let low = AudioDescriptors.measure(sine(100, amp: 0.5, seconds: 1))
        let high = AudioDescriptors.measure(sine(4000, amp: 0.5, seconds: 1))
        #expect(low.centroid < 200 && high.centroid > 3500)
        #expect(low.bands[1] > 0.9 && high.bands[3] > 0.9)
        #expect(abs((low.tone ?? 0) - 100) < 3 && AudioDescriptors.note(low.tone ?? 0) == "G2")
        #expect(abs((high.tone ?? 0) - 4000) < 10)
        #expect(low.words.contains("dark") && high.words.contains("bright"))

        let click = AudioDescriptors.measure(sine(800, amp: 0.8, seconds: 0.6) { exp(-$0 * 30) })
        let swell = AudioDescriptors.measure(sine(800, amp: 0.8, seconds: 0.6) { min(1, $0 / 0.3) * min(1, (0.6 - $0) / 0.05) })
        #expect((click.attackMs ?? 99) < 6 && (swell.attackMs ?? 0) > 150)
        #expect(click.words.contains("sharp attack") && swell.words.contains("slow swell"))
        #expect((click.decayMs ?? 999) < 120)

        // Faults: starts mid-wave, clipped, silent lead-in.
        var bad = sine(200, amp: 1.2, seconds: 0.3)
        bad.l = bad.l.map { min(1, max(-1, $0)) }; bad.r = bad.l
        let d = AudioDescriptors.measure(Stereo(l: Array(bad.l[60...]), r: Array(bad.r[60...])))
        #expect(d.clipped && d.abruptStart)
        var late = Stereo(count: 9600)
        let body = sine(500, amp: 0.5, seconds: 0.3) { min(1, $0 / 0.01) * min(1, (0.3 - $0) / 0.02) }
        late.l += body.l; late.r += body.r
        let ld = AudioDescriptors.measure(late)
        #expect(abs(ld.lead - 0.2) < 0.01 && ld.faults.contains { $0.contains("silence before") })
    }

    @Test func mixIsTheSumOfClipsAndTheReportFindsProblems() throws {
        let project = try TempProject("mix")
        defer { project.remove() }
        let dir = project.url
        func fade(_ d: Double) -> (Double) -> Double { { min(1, $0 / 0.02) * min(1, (d - $0) / 0.02) } }
        try write(sine(300, amp: 0.1, seconds: 4, env: fade(4)), to: dir.appendingPathComponent("voice.wav"))
        try write(sine(1500, amp: 0.5, seconds: 0.5, env: fade(0.5)), to: dir.appendingPathComponent("hit.wav"))
        try write(sine(905, amp: 0.3, seconds: 2), to: dir.appendingPathComponent("drone.wav"))

        var s = Scene(id: "s", duration: 4)
        s.audio = AudioRef(src: "voice.wav")
        var loud = AudioRef(src: "hit.wav"); loud.id = "loud"; loud.offset = 1.6
        var quiet = AudioRef(src: "hit.wav"); quiet.id = "quiet"; quiet.offset = 2.5; quiet.gain = 0.002
        var cut = AudioRef(src: "drone.wav"); cut.id = "cut"; cut.offset = 0.5; cut.trim = 0.0003; cut.length = 1; cut.gain = 0.2
        s.sounds = [loud, quiet, cut]
        s.markers = [Marker(name: "beat", t: 1.5)]

        let r = SceneMix.render(s, assets: dir)
        #expect(r.stems.count == 4 && r.mix.count == Int(4 * Stereo.rate))
        // Sample by sample, the mix is voice + clips with their gains.
        let voice = try Stereo.read(dir.appendingPathComponent("voice.wav"))
        let hit = try Stereo.read(dir.appendingPathComponent("hit.wav"))
        let i = Int(1.8 * Stereo.rate)
        #expect(abs(r.mix.l[i] - (voice.l[i] + hit.l[i - Int(1.6 * Stereo.rate)])) < 1e-4)

        let report = MixReport.make(s, rendered: r)
        #expect(abs((report.referenceLufs ?? 0) - -20.5) < 1.5)
        let row = try #require(report.rows.first { $0.id == "loud" })
        #expect(row.level > (row.reference ?? 0) + 8 && row.marker == "beat +0.1s")
        #expect(report.warnings.contains { $0.contains("'loud'") && $0.contains("competes with the scene audio") })
        #expect(report.warnings.contains { $0.contains("'quiet'") && $0.contains("buried") })
        #expect(report.warnings.contains { $0.contains("'cut'") && $0.contains("starts mid-sound") })
        #expect(report.warnings.contains { $0.contains("'cut'") && $0.contains("cut mid-sound at 1.5") })
        #expect(report.text.contains("problems:"))

        // The fixes clear the warnings.
        s.sounds?[0].gain = 0.06
        s.sounds?[1].gain = 0.04
        s.sounds?[2].fadeIn = 0.03; s.sounds?[2].fadeOut = 0.05
        let fixed = MixReport.make(s, rendered: SceneMix.render(s, assets: dir))
        #expect(fixed.warnings.isEmpty, "\(fixed.warnings)")

        // Over full scale: flagged.
        s.sounds?[0].gain = 2.5
        #expect(MixReport.make(s, rendered: SceneMix.render(s, assets: dir)).warnings.first?.contains("distort") == true)

        // The picture renders.
        let img = try AudioSheet.render(r.mix, lanes: [.init(label: "loud", from: 1, to: 1.5)], marks: [("beat", 0.9)])
        #expect(img.width == 1400 && img.height > 300)
    }

    @Test func toolsMeasureAndSetLevels() throws {
        let project = try TempProject("eartools", scenes: [Scene(id: "s", duration: 4)])
        defer { project.remove() }
        let assets = project.store.assetsURL
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try write(sine(300, amp: 0.1, seconds: 4) { min(1, $0 / 0.02) * min(1, (4 - $0) / 0.02) }, to: assets.appendingPathComponent("voice.wav"))
        let server = MCPServer(projectPath: project.url.path)
        func call(_ name: String, _ args: [String: JSONValue]) throws -> [JSONValue] {
            guard let tool = server.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
            return try tool.run(args)
        }
        func run(_ tool: String, _ args: [String: JSONValue]) throws -> String {
            try call(tool, args).compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
        }
        _ = try run("scene_apply", ["scene": "s", "ops": [["op": "scene", "audio": ["src": "voice.wav"]]]])
        // level: 10 dB under the voice, whatever the file's own loudness.
        let out = try run("sound_synth", ["preset": "pop", "scene": "s", "at": 1, "level": -10])
        #expect(out.contains("measured:") && out.contains("10 dB under the scene audio"))
        #expect(out.contains("at gain 0."))

        let mix = try call("mix_check", ["scene": "s"])
        let mixImage = mix.contains { $0.object?["type"]?.string == "image" }
        #expect(mixImage)
        let txt = mix.compactMap { $0.object?["text"]?.string }.joined()
        #expect(txt.contains("LUFS integrated") && txt.contains("pop") && txt.contains("no problems measured"))

        let an = try call("audio_analyze", ["src": "voice.wav", "image": true])
        let anImage = an.contains { $0.object?["type"]?.string == "image" }
        #expect(anImage)
        let anText = an.compactMap { $0.object?["text"]?.string }.joined()
        #expect(anText.contains("character:"))
    }
}
