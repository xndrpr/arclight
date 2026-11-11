import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

struct AIPanelTests {
    let here = URL(fileURLWithPath: "/tmp/Here.arclight")

    func agent(_ pid: Int32, _ client: String, project: String?) -> AgentPresence {
        AgentPresence(pid: pid, client: client, project: project)
    }

    @Test func statusPill() {
        let now = Date()
        #expect(AIStatus.compute(agents: [], project: here, now: now).kind == .none)
        #expect(
            AIStatus.compute(agents: [], project: here, legacyActiveUntil: now.addingTimeInterval(2), now: now).text
                == "AI is editing…")

        var a = agent(1, "claude-code", project: here.path)
        #expect(AIStatus.compute(agents: [a], project: here, now: now).text == "Claude Code connected")
        a.begin("scene_get", writes: false)
        #expect(AIStatus.compute(agents: [a], project: here, now: now).text == "Claude Code is reading…")
        a.begin("scene_apply", writes: true)
        let s = AIStatus.compute(agents: [a], project: here, now: now)
        #expect(s.kind == .editing && s.text == "Claude Code is editing…" && s.agent == 1)

        // Busy on another project: just "connected" here.
        var b = agent(2, "cursor", project: "/tmp/Other.arclight")
        b.begin("scene_apply", writes: true)
        #expect(AIStatus.compute(agents: [b], project: here, now: now).kind == .connected)
        #expect(
            AIStatus.compute(agents: [b, agent(3, "x", project: nil)], project: here, now: now).text
                == "2 AI agents connected")
    }

    @Test func panelWidthsKeepTheViewport() {
        // Plenty of room: unchanged.
        #expect(PanelWidths.fit(total: 1800, left: 210, right: 360) == PanelWidths(left: 210, right: 360))
        // Tighter: the left sidebar shrinks first, then the inspector; the viewport keeps its minimum.
        let tight = PanelWidths.fit(total: 950, left: 210, right: 360)
        #expect(tight.left == PanelWidths.mins.left && tight.right < 360)
        #expect(tight.left + tight.right + PanelWidths.minCenter + 2 * PanelWidths.handle <= 950)
    }

    // MARK: Floating AI panel

    let container = CGSize(width: 900, height: 700)
    let m = CGFloat(AIPanelLayout.margin)

    @Test func floatingPanelDefaultsTopRight() {
        let f = AIPanelLayout().frame(in: container)
        #expect(f.maxX == container.width - m && f.minY == CGFloat(AIPanelLayout.topMargin))
        #expect(f.size == AIPanelLayout.defaultSize)
    }

    @Test func floatingPanelSnapsToCorners() {
        let l = AIPanelLayout()
        let s = AIPanelLayout.defaultSize
        // Released near the bottom-left corner: snaps into it.
        let nearBL = CGRect(x: m + 20, y: container.height - m - s.height - 25, width: s.width, height: s.height)
        let a = l.settled(nearBL, in: container)
        #expect(a.corner == .bottomLeading && a.dx == 0 && a.dy == 0)
        #expect(a.frame(in: container).minX == m && a.frame(in: container).maxY == container.height - m)
        // Released away from any corner: stays where it was dropped, anchored to the nearest corner.
        let free = CGRect(x: 420, y: 60 + AIPanelLayout.topMargin, width: 340, height: 300)
        var small = l; small.height = 300
        let b = small.settled(free, in: container)
        #expect(b.corner == .topTrailing && b.dy == 60 && b.dx > 40)
        #expect(b.frame(in: container) == free)
        // Dragged past the edge: clamped back inside before settling.
        let out = CGRect(x: -200, y: -80, width: s.width, height: s.height)
        let c = l.settled(out, in: container)
        #expect(c.corner == .topLeading && c.dx == 0 && c.dy == 0)
    }

    @Test func floatingPanelStaysOnScreenWhenTheWindowShrinks() {
        var l = AIPanelLayout(corner: .bottomLeading, dx: 300, dy: 200, width: 500, height: 600)
        for c in [CGSize(width: 900, height: 700), CGSize(width: 520, height: 420), CGSize(width: 410, height: 310)] {
            let f = l.frame(in: c)
            #expect(
                f.minX >= m && f.minY >= CGFloat(AIPanelLayout.topMargin) && f.maxX <= c.width - m
                    && f.maxY <= c.height - m, "\(c) → \(f)")
            #expect(!l.isSheet(in: c))
        }
        // Keeps its distance from its corner while there is room.
        let big = CGSize(width: 1400, height: 1000)
        #expect(l.frame(in: big).minX == m + 300 && l.frame(in: big).maxY == big.height - m - 200)
        // Tiny container: becomes a sheet over the whole viewport.
        let tiny = CGSize(width: 360, height: 500)
        #expect(l.isSheet(in: tiny) && l.frame(in: tiny) == CGRect(origin: .zero, size: tiny).insetBy(dx: 6, dy: 6))
        // Collapsed: just the header, still anchored to its corner.
        l.collapsed = true
        let f = l.frame(in: big)
        #expect(f.height == CGFloat(AIPanelLayout.headerHeight) && f.maxY == big.height - m - 200)
    }

    @Test func floatingPanelResizeIsClamped() {
        let l = AIPanelLayout()
        let start = l.frame(in: container)
        // Bottom-left handle grows leftwards and down; the right and top edges stay put.
        let a = l.resized(from: start, by: CGSize(width: -100, height: 50), leadingHandle: true, in: container)
        let fa = a.frame(in: container)
        #expect(
            fa.maxX == start.maxX && fa.minY == start.minY && fa.width == start.width + 100
                && fa.height == start.height + 50)
        // Can't go below the minimum or past the container.
        let b = l.resized(from: start, by: CGSize(width: 900, height: -900), leadingHandle: true, in: container)
        #expect(b.width == Double(AIPanelLayout.minSize.width) && b.height == Double(AIPanelLayout.minSize.height))
        let c = l.resized(from: start, by: CGSize(width: 900, height: 900), leadingHandle: false, in: container)
        let fc = c.frame(in: container)
        #expect(fc.maxX <= container.width - m && fc.maxY <= container.height - m)
    }

    @Test func floatingPanelPersistence() throws {
        let l = AIPanelLayout(corner: .bottomLeading, dx: 12, dy: 30, width: 400, height: 500, collapsed: true)
        #expect(AIPanelLayout.decode(l.encoded) == l)
        // Garbage and partial data fall back field by field.
        #expect(AIPanelLayout.decode("not json") == nil)
        let partial = try #require(AIPanelLayout.decode(#"{"corner":"nowhere","dx":-5,"width":380}"#))
        #expect(partial.corner == .topTrailing && partial.dx == 0 && partial.width == 380 && partial.height == 560)

        let defaults = try TempDefaults()
        defer { defaults.remove() }
        let d = try defaults.suite("aiFloat")
        // The old sidebar width becomes the panel width once, then the old key is gone.
        d.set(300.0, forKey: Pref.legacyAIWidth)
        #expect(AIPanelLayout.load(d).width == 300)
        #expect(d.object(forKey: Pref.legacyAIWidth) == nil)
        #expect(AIPanelLayout.load(d).width == 300)
        l.save(d)
        #expect(AIPanelLayout.load(d) == l)
    }

    @Test func canvasPresetTitlesAreDistinct() {
        let titles = EditorDocument.presets.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(EditorDocument.presets.first { $0.w == 3840 }?.title == "4K UHD")
    }
}
