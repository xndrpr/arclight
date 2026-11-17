import AVFoundation
import Foundation
import Testing

@testable import ArclightCore

@Suite(.serialized) struct PitchShiftTests {
    /// Zero crossings per second / 2 over the middle of the file (skips the edges).
    private func frequency(_ url: URL) throws -> (Double, Int) {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let x = buf.floatChannelData![0]
        let n = Int(buf.frameLength), a = n / 4, b = 3 * n / 4
        var crossings = 0
        for i in (a + 1)..<b where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        return (Double(crossings) / 2 / (Double(b - a) / f.processingFormat.sampleRate), n)
    }

    /// Time (s) of the first sample louder than `level`.
    private func onset(_ url: URL, level: Float) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let x = buf.floatChannelData![0]
        for i in 0..<Int(buf.frameLength) where abs(x[i]) > level { return Double(i) / f.processingFormat.sampleRate }
        return .infinity
    }

    @Test func clipPitchRendersAShiftedCopyOfTheSameLength() throws {
        let project = try TempProject("pitch")
        defer { project.remove() }
        let dir = project.url
        try tone(dir.appendingPathComponent("tone.wav"), amplitude: { $0 < 0.5 ? 0 : 0.5 })
        var ref = AudioRef(src: "tone.wav")
        #expect(SceneAudio.url(ref, assets: dir).lastPathComponent == "tone.wav")
        ref.pitch = -12
        let low = SceneAudio.url(ref, assets: dir)
        #expect(low.lastPathComponent != "tone.wav")
        #expect(SceneAudio.url(ref, assets: dir) == low)  // cached

        let (f0, n0) = try frequency(dir.appendingPathComponent("tone.wav"))
        let (f1, n1) = try frequency(low)
        #expect(abs(f0 - 440) < 5)
        #expect(abs(f1 - 220) < 10)
        #expect(n1 == n0)
        // Latency is trimmed: the tone still starts at 0.5 s.
        #expect(abs(try onset(low, level: 0.05) - 0.5) < 0.03)
    }

    @Test func soundOpTakesAndChecksPitch() throws {
        var s = Scene(id: "s", duration: 3)
        s = try SceneOps.apply([["op": "sound", "id": "a", "src": "a.wav", "pitch": -3]], to: s).scene
        #expect(s.sound("a")?.pitch == -3)
        s = try SceneOps.apply([["op": "sound", "id": "a", "pitch": .null]], to: s).scene
        #expect(s.sound("a")?.pitch == nil)
        #expect(throws: (any Error).self) {
            try SceneOps.apply([["op": "sound", "id": "a", "pitch": 30]], to: s)
        }
    }
}
