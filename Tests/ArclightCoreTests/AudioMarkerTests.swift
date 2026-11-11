import AVFoundation
import Foundation
import Testing

@testable import ArclightCore

@Suite(.serialized) struct AudioMarkerTests {
    @Test func markersOpsExpressionsAndOutline() throws {
        var s = Scene(id: "s", duration: 5)
        s.nodes = [Node(id: "a", type: "group", props: ["x": .expr("t >= marker('hit') ? 100 : 0")])]
        s = try SceneOps.apply(
            [["op": "marker", "name": "hit", "t": 2], ["op": "marker", "name": "intro", "t": 0.5]], to: s
        ).scene
        #expect(s.markers?.map(\.name) == ["intro", "hit"])
        let ev = Evaluator()
        #expect(ev.evaluate(s, T: 1).first?.world.columns.3.x == 0)
        #expect(ev.evaluate(s, T: 2.5).first?.world.columns.3.x == 100)
        #expect(Outline.scene(s, project: Project(name: "p")).contains("markers: intro@0.5, hit@2"))
        s = try SceneOps.apply([["op": "marker", "name": "hit", "remove": true]], to: s).scene
        #expect(s.markers?.map(\.name) == ["intro"])
        #expect(throws: (any Error).self) { try SceneOps.apply([["op": "marker", "name": "x"]], to: s) }
    }

    @Test func waveformPeaks() throws {
        let project = try TempProject("aud")
        let dir = project.url
        defer { project.remove() }
        let wav = dir.appendingPathComponent("tone.wav")
        try tone(wav, channels: 2, amplitude: { $0 < 0.5 ? 0.2 : 0.8 })
        #expect(abs((SceneAudio.info(wav)?.duration ?? 0) - 2) < 0.01)
        let p = SceneAudio.peaks(wav, buckets: 100)
        #expect(p.count == 100)
        #expect(p[10] > 0.15 && p[10] < 0.25 && p[80] > 0.7)  // quiet first half, loud second half
    }

    @Test(.requiresMetal) func exportMuxesAudioAndKeepsAlpha() throws {
        let project = try TempProject("mux")
        let dir = project.url
        defer { project.remove() }
        try tone(dir.appendingPathComponent("tone.wav"), channels: 2, amplitude: { $0 < 0.5 ? 0.2 : 0.8 })
        var s = Scene(id: "s", duration: 1.5)
        s.nodes = [
            Node(
                id: "r", type: "shape",
                props: ["x": .value(100), "y": .value(50), "width": .value(80), "height": .value(40)])
        ]
        var a = AudioRef(src: "tone.wav"); a.offset = 0.5; a.fadeOut = 0.2
        s.audio = a
        let p = Project(name: "p", size: [320, 180])
        let ex = Exporter(renderer: try Renderer())
        for fmt in [ExportFormat.mp4, .prores] {
            var o = ExportOptions(); o.format = fmt
            let out = dir.appendingPathComponent("s.\(fmt.ext)")
            _ = try ex.export(scene: s, project: p, assets: dir, to: out, options: o)
            let asset = AVURLAsset(url: out)
            let (aTracks, vTracks, dur, sub) = try SceneAudio.sync {
                let at = try await asset.loadTracks(withMediaType: .audio)
                let vt = try await asset.loadTracks(withMediaType: .video)
                let d = try await asset.load(.duration).seconds
                let fd = try await vt.first?.load(.formatDescriptions).first
                return (at.count, vt.count, d, fd.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0)
            }
            #expect(aTracks == 1 && vTracks == 1, "\(fmt) has audio + video")
            #expect(abs(dur - 1.5) < 0.1, "\(fmt) duration \(dur)")
            if fmt == .prores { #expect(sub == kCMVideoCodecType_AppleProRes4444, "ProRes 4444 kept (alpha)") }
        }
    }
}
