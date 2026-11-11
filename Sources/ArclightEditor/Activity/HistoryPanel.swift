import ArclightCore
import SwiftUI

/// Renders small frames of saved revisions one at a time, deferred so scrolling stays smooth. Cached by scene/rev/time.
private final class RevisionThumbs: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var queue: [(key: String, job: () -> CGImage?)] = []
    private var running = false
    private var snapshots: [String: Scene] = [:]
    /// Time of the last requested frame; rows keep showing it while playing instead of re-rendering every tick.
    private(set) var lastTime: Double = 0

    static func key(_ scene: String, _ rev: Int, _ t: Double, _ w: Double) -> String {
        "\(scene):\(rev):\(Int((t * 1000).rounded())):\(Int(w))"
    }

    /// A saved revision (cached; history files never change).
    func snapshot(_ doc: EditorDocument, _ sceneId: String, _ rev: Int) -> Scene? {
        let k = "\(sceneId):\(rev)"
        if let s = snapshots[k] { return s }
        let s = doc.store.snapshot(sceneId, rev: rev)
        if let s { snapshots[k] = s }
        return s
    }

    func request(_ doc: EditorDocument, scene sceneId: String, rev: Int, time t: Double, width: Double) {
        let k = Self.key(sceneId, rev, t, width)
        lastTime = t
        guard images[k] == nil, !queue.contains(where: { $0.key == k }) else { return }
        queue.append(
            (
                k,
                { [weak self, weak doc] in
                    guard let self, let doc, let s = self.snapshot(doc, sceneId, rev) else { return nil }
                    return doc.preview(s, time: t, width: width * 2)
                }
            ))
        pump()
    }

    func cancel(_ key: String) { queue.removeAll { $0.key == key } }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.running = false
            // Rows may cancel their jobs while we wait (scrolling, switching tabs), so the queue can be empty here.
            guard !self.queue.isEmpty else { return }
            self.running = true
            let next = self.queue.removeFirst()
            if let img = next.job() {
                if self.images.count > 400 { self.images.removeAll() }
                self.images[next.key] = img
            }
            self.running = false
            self.pump()
        }
    }
}

/// Saved revisions of the current scene, newest first: who saved, what changed, a frame at the playhead, restore/compare.
struct HistoryPanel: View {
    @ObservedObject var doc: EditorDocument
    @StateObject private var thumbs = RevisionThumbs()
    @State private var entries: [ProjectStore.HistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(doc.scene.name ?? doc.scene.id).font(UI.small.weight(.medium)).foregroundStyle(UI.label2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(entries.count) saved version\(entries.count == 1 ? "" : "s")").font(UI.monoSmall)
                    .foregroundStyle(UI.faint)
                    .contentTransition(.numericText())
                    .help("Every save of this scene, by you or an AI agent. Hover a version to restore or compare it.")
            }
            .padding(.horizontal, 12).frame(height: 32)
            Hairline()
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 20)).foregroundStyle(UI.faint)
                    Text("No saved versions yet").font(UI.font).foregroundStyle(UI.label2)
                    Text(
                        "Every save of this scene — yours or an AI agent's — is kept here, so you can compare and go back anytime."
                    )
                    .font(UI.small).foregroundStyle(UI.dim).multilineTextAlignment(.center).fixedSize(
                        horizontal: false, vertical: true)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries.reversed()) { h in
                            HistoryRow(doc: doc, thumbs: thumbs, entry: h, current: h.rev == doc.scene.rev)
                                .transition(Motion.row)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear { entries = doc.history() }
        .onChange(of: doc.scene.id) { _, _ in entries = doc.history() }
        .onChange(of: doc.scene.rev) { _, _ in reload() }
    }

    /// A new save drops in at the top (no animation during playback).
    private func reload() {
        let e = doc.history()
        guard e.map(\.rev) != entries.map(\.rev) || e.map(\.time) != entries.map(\.time) else { return }
        if doc.playing { entries = e } else { withMotion(Motion.snappy) { entries = e } }
    }
}

private struct HistoryRow: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var thumbs: RevisionThumbs
    let entry: ProjectStore.HistoryEntry
    let current: Bool
    @State private var hover = false
    @State private var comparing = false

    private let thumbW: Double = 64

    var body: some View {
        let h = entry
        let sceneId = doc.scene.id
        let t = doc.playing ? thumbs.lastTime : (doc.time * doc.fps).rounded() / doc.fps
        let key = RevisionThumbs.key(sceneId, h.rev, t, thumbW)
        let aspect = doc.canvasSize.height / max(doc.canvasSize.width, 1)
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Rectangle().fill(UI.field)
                if let img = thumbs.images[key] {
                    Image(decorative: img, scale: 2).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: thumbW, height: max(18, min(80, thumbW * aspect)))
            .overlay(Rectangle().stroke(current ? UI.accent : UI.border, lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                if current {
                    Text("CURRENT").font(.system(size: 7.5, weight: .bold)).tracking(0.4).foregroundStyle(UI.onAccent)
                        .padding(.horizontal, 3).frame(height: 11).background(UI.accent)
                }
            }
            .onAppear { thumbs.request(doc, scene: sceneId, rev: h.rev, time: t, width: thumbW) }
            .onChange(of: key) { old, _ in
                thumbs.cancel(old); thumbs.request(doc, scene: sceneId, rev: h.rev, time: t, width: thumbW)
            }
            .onDisappear { thumbs.cancel(key) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SourceIcon(source: h.source)
                    Text("rev \(h.rev)").font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UI.text)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 2)
                    RelativeTime(date: Timestamp.parse(h.time))
                }
                Text(h.summary).font(UI.small).foregroundStyle(UI.label2).lineLimit(3).fixedSize(
                    horizontal: false, vertical: true)
                if let ch = h.changed, !ch.isEmpty, !(h.summary.contains(ch[0])) {
                    Text(ch.prefix(4).joined(separator: ", ") + (ch.count > 4 ? " +\(ch.count - 4)" : ""))
                        .font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? UI.hover : .clear)
        // Hover actions are an overlay: inserting them made the row taller, the rows below jumped and the hover
        // toggled back and forth under the pointer (flicker).
        .overlay(alignment: .bottomTrailing) { if !current { actions(h) } }
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .onHover { h in withMotion(UI.fade) { hover = h } }
    }

    /// Restore / Compare, invisible until hover. Always laid out so the Compare popover keeps its anchor.
    private func actions(_ h: ProjectStore.HistoryEntry) -> some View {
        let shown = hover || comparing
        return HStack(spacing: 4) {
            ConfirmButton(
                title: "Restore", confirmTitle: "Confirm", help: "Restore rev \(h.rev) as a new revision (undoable)"
            ) {
                doc.restore(rev: h.rev)
            }
            SmallButton(
                title: "Compare", symbol: "rectangle.split.2x1", help: "This revision next to the current scene"
            ) { comparing = true }
            .popover(isPresented: $comparing, arrowEdge: .trailing) {
                CompareView(doc: doc, thumbs: thumbs, rev: h.rev, source: h.source)
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
        .background(
            LinearGradient(
                stops: [.init(color: UI.hover.opacity(0), location: 0), .init(color: UI.hover, location: 0.2)],
                startPoint: .leading, endPoint: .trailing)
        )
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
    }
}

/// Side by side: a saved revision and the current working scene at the playhead, plus what differs.
private struct CompareView: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var thumbs: RevisionThumbs
    let rev: Int
    let source: String?
    @State private var current: CGImage?

    private let w: Double = 300

    var body: some View {
        let t = (doc.time * doc.fps).rounded() / doc.fps
        let key = RevisionThumbs.key(doc.scene.id, rev, t, w)
        let old = thumbs.snapshot(doc, doc.scene.id, rev)
        let aspect = doc.canvasSize.height / max(doc.canvasSize.width, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compare at \(String(format: "%.2f", t))s").font(UI.font.weight(.semibold)).foregroundStyle(
                    UI.text)
                Spacer()
                if let old {
                    Text(SceneDiff.diff(old, doc.scene).summary).font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(2)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                frame(thumbs.images[key], label: "rev \(rev)", icon: source, aspect: aspect)
                frame(current, label: "Current · rev \(doc.scene.rev)", icon: nil, aspect: aspect)
            }
            HStack {
                Spacer()
                ConfirmButton(title: "Restore rev \(rev)", confirmTitle: "Confirm restore") { doc.restore(rev: rev) }
            }
        }
        .padding(14)
        .background(UI.panel)
        .onAppear {
            thumbs.request(doc, scene: doc.scene.id, rev: rev, time: t, width: w); renderCurrent(t)
        }
        .onChange(of: key) { _, _ in
            thumbs.request(doc, scene: doc.scene.id, rev: rev, time: t, width: w); renderCurrent(t)
        }
        .onChange(of: doc.scene) { _, _ in renderCurrent(t) }
    }

    private func frame(_ img: CGImage?, label: String, icon: String?, aspect: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Rectangle().fill(UI.field)
                if let img {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: w, height: w * aspect)
            .overlay(Rectangle().stroke(UI.border, lineWidth: 1))
            HStack(spacing: 4) {
                if let icon { SourceIcon(source: icon) }
                Text(label).font(UI.monoSmall).foregroundStyle(UI.label2)
            }
        }
    }

    private func renderCurrent(_ t: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            current = doc.preview(doc.scene, time: t, width: w * 2)
        }
    }
}
