import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Pins the timeline's zoom and pan limits (EditorDocument) and the canvas viewport's (ViewZoom).
@Suite(.serialized) struct TimelineZoomTests {
    /// A 4 s scene at 30 fps whose last keyframe is at 6 s (content runs past END).
    func makeDoc() throws -> (EditorDocument, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-zoom-\(UUID().uuidString).arclight")
        let store = try ProjectStore.create(at: dir, name: "t")
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [Node(id: "a", type: "shape", props: ["x": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 5, v: 1)])])]
        s.nodes[0].start = 1
        try store.save(scene: s)
        let doc = try EditorDocument(url: dir)
        doc.zoomToFit(animated: false)
        return (doc, dir)
    }

    @Test(.requiresMetal) func clampedTimeAndSnapTolerance() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(doc.clampedTime(-2) == 0 && doc.clampedTime(3.5) == 3.5 && doc.clampedTime(1e9) == doc.maxTime)
        let map = TimeMap(doc: doc, width: 408)  // 400 pt of track over the 8 s fit span: 50 pt/s
        #expect(map.snapTolerance == Double(6 / map.pps) && abs(map.snapTolerance - 0.12) < 1e-9)
    }

    @Test(.requiresMetal) func scrubStopsPlaybackAndClamps() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        doc.playing = true
        doc.scrub(to: 2.01, tolerance: 0)  // frame-rounded (30 fps), no snap target within 0
        #expect(!doc.playing && abs(doc.time - 2) < 1e-9)
        doc.playing = true
        doc.scrub(to: -3, tolerance: 0)
        #expect(!doc.playing && doc.time == 0)
        doc.scrub(to: 1e9, tolerance: 0)
        #expect(doc.time == doc.maxTime)
    }

    @Test(.requiresMetal) func fitSpanAndContentEnd() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(doc.contentEnd == 6)  // start 1 + last key 5
        #expect(doc.fitSpan() == 8)  // + max(2, 25%)
        #expect(doc.tlVisible == 8 && doc.tlOffset == 0 && doc.tlZoom == 1)
        #expect(doc.maxVisible == 60)  // max(fit × 4, 60), capped by the pan limit
        #expect(doc.panLimit == 6 * 3600 && doc.maxTime == 6 * 3600)
    }

    @Test(.requiresMetal) func zoomIsClampedAndKeepsTheAnchor() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Zooming in around t = 2 keeps 2 s at the same place on screen.
        doc.zoomTimeline(by: 2, anchor: 2)
        #expect(doc.tlVisible == 4 && abs(doc.tlOffset - 1) < 1e-9)
        // Never closer than 12 frames across.
        doc.zoomTimeline(by: 1000, anchor: 2)
        #expect(abs(doc.tlVisible - 12.0 / 30) < 1e-9)
        // Never further out than maxVisible; the offset can't go below 0.
        doc.zoomTimeline(by: 0.0001, anchor: 2)
        #expect(doc.tlVisible == 60 && doc.tlOffset == 0)
        // Without an anchor the playhead is the anchor.
        doc.zoomToFit(animated: false)
        doc.time = 4
        doc.zoomTimeline(by: 4)
        #expect(doc.tlVisible == 2 && abs(doc.tlOffset - 3) < 1e-9)
    }

    @Test(.requiresMetal) func panIsClamped() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        doc.setTimelineOffset(-5)
        #expect(doc.tlOffset == 0)
        doc.setTimelineOffset(100)
        #expect(doc.tlOffset == 100)
        doc.setTimelineOffset(1e9)
        #expect(doc.tlOffset == doc.panLimit - doc.tlVisible)
        // Fit resets the pan.
        doc.zoomToFit(animated: false)
        #expect(doc.tlOffset == 0 && doc.tlVisible == 8)
    }

    @Test(.requiresMetal) func stepAndSnapStayOnFrames() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        doc.time = 0
        doc.step(-5)
        #expect(doc.time == 0)
        doc.step(45)
        #expect(doc.time == 1.5)
        doc.snapping = false
        #expect(abs(doc.snapTime(1.01, tolerance: 1) - 1.0) < 1e-9)
        doc.snapping = true
        // Snaps to the playhead or a key / edge within the tolerance; frames otherwise.
        #expect(doc.snapTime(1.45, tolerance: 0.1) == 1.5)
        #expect(doc.snapTime(5.97, tolerance: 0.1) == 6)
        #expect(abs(doc.snapTime(3.21, tolerance: 0.01) - 3.2) < 1e-9)
    }

    @Test func viewportZoomLimits() {
        #expect(ViewZoom.minScale == 0.05 && ViewZoom.maxScale == 8)
        #expect(ViewZoom.clamp(0.001) == 0.05 && ViewZoom.clamp(100) == 8 && ViewZoom.clamp(1.5) == 1.5)
    }
}
