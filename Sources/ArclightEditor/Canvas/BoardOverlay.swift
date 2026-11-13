import AppKit
import ArclightCore
import SwiftUI

/// Preview workspace: the page's other artboards drawn around the open one (live, editable) at their board
/// positions, Figma-style, with a name label above every artboard. Click an artboard to open it; drag a label to
/// move that artboard on the board.
struct BoardOverlay: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var vp: ViewportState
    /// Top-left of the open canvas in viewport points, and the scale.
    let origin: CGPoint
    let scale: CGFloat
    @State private var dragging: String?
    @State private var drag: CGSize = .zero

    var body: some View {
        let rects = doc.boardRects()
        let open = doc.target.artboardId
        ZStack(alignment: .topLeading) {
            ForEach(rects, id: \.artboard.id) { item in
                let off = dragging == item.artboard.id ? drag : .zero
                let r = viewRect(item.rect).offsetBy(dx: off.width, dy: off.height)
                if item.artboard.id != open {
                    BoardTile(doc: doc, artboard: item.artboard, pixelWidth: r.width)
                        .frame(width: r.width, height: r.height)
                        .overlay(Rectangle().stroke(UI.border, lineWidth: 1))
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { openArtboard(item.artboard.id) }
                        .help("Click to edit \(item.artboard.name ?? item.artboard.id)")
                        .cursor(.pointingHand)
                }
                label(item.artboard, open: item.artboard.id == open)
                    .position(x: r.minX, y: r.minY - 11)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(
            x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale,
            height: r.height * scale)
    }

    private func openArtboard(_ id: String) {
        guard let p = doc.target.previewId else { return }
        // Keep the clicked artboard where it is on screen: the new open canvas centre is its centre.
        if let r = doc.boardRects().first(where: { $0.artboard.id == id })?.rect {
            let s = vp.scale, cs = doc.canvasSize
            let p2 = CGSize(
                width: vp.pan.width + (r.midX - cs.width / 2) * s, height: vp.pan.height + (r.midY - cs.height / 2) * s)
            DispatchQueue.main.async { vp.setPan(p2) }  // after the canvas size (and board) update
        }
        doc.open(preview: p, artboard: id)
    }

    private func label(_ a: Artboard, open: Bool) -> some View {
        Text("\(a.name ?? a.id)  \(String(a.width))×\(String(a.height))")
            .font(.system(size: 10.5, weight: open ? .semibold : .regular))
            .foregroundStyle(open ? UI.text : UI.dim)
            .lineLimit(1).fixedSize()
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            // `position` centres the label: shift it so its leading edge sits on the artboard's left edge.
            .modifier(LeadingAnchor())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { g in dragging = a.id; drag = g.translation }
                    .onEnded { g in
                        let d = CGSize(width: g.translation.width / scale, height: g.translation.height / scale)
                        let wasOpen = open
                        dragging = nil; drag = .zero
                        doc.moveArtboard(a.id, by: d)
                        // Board coordinates are relative to the open artboard: moving it moves the view with it.
                        if wasOpen { vp.setPan(CGSize(width: vp.pan.width + g.translation.width, height: vp.pan.height + g.translation.height)) }
                    }
            )
            .onTapGesture { if !open { openArtboard(a.id) } }
            .cursor(.openHand)
            .help("Drag to move this artboard · click to edit it")
    }
}

/// Shifts a `position`ed view right by half its width, so `position(x:)` names its leading edge.
private struct LeadingAnchor: ViewModifier {
    @State private var w: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.onAppear { w = g.size.width }.onChange(of: g.size.width) { _, v in w = v } })
            .offset(x: w / 2)
    }
}

/// A rendered (not live) artboard: cached by page revision and a width bucket, so zooming re-renders sharper.
struct BoardTile: View {
    @ObservedObject var doc: EditorDocument
    let artboard: Artboard
    let pixelWidth: CGFloat
    @State private var image: CGImage?

    var body: some View {
        let width = Self.bucket(pixelWidth * 2, max: artboard.width)
        let scene = artboard.asScene(preview: doc.target.previewId ?? "", rev: doc.openPreview?.rev ?? 0)
        ZStack {
            Rectangle().fill(UI.panel)
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high) }
        }
        .task(id: TileKey(scene: scene, width: width, theme: doc.project.theme)) {
            image = await LibraryThumbs.shared.scene(scene, project: doc.project, projectURL: doc.url, width: width)
        }
    }

    /// 256, 512, 1024 or 2048 px wide (never wider than the artboard itself).
    static func bucket(_ w: CGFloat, max m: Int) -> Int {
        for b in [256, 512, 1024, 2048] where CGFloat(b) >= w { return min(b, m) }
        return min(2048, m)
    }
}

/// A floating mini view of the open artboard at YouTube feed size, with the timestamp badge, in the corner of the
/// viewer: what most viewers see first.
struct FeedPreview: View {
    @ObservedObject var doc: EditorDocument
    @State private var image: CGImage?
    @AppStorage(Pref.feedPreview) private var on = false

    var body: some View {
        let scene = doc.scene
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("FEED SIZE").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(UI.dim)
                Spacer()
                Button { on = false } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
                }
                .buttonStyle(.plain).help("Hide the feed preview")
            }
            HStack(alignment: .top, spacing: 8) {
                tile(width: 246, dark: true)
                tile(width: 168, dark: false)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(UI.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(UI.border))
        .task(id: FeedKey(scene: scene, theme: doc.project.theme)) {
            try? await Task.sleep(nanoseconds: 250_000_000)  // debounce while dragging
            guard !Task.isCancelled else { return }
            image = doc.preview(scene, time: 0, width: 492).map { FeedMock.badge($0) }
        }
    }

    private func tile(width: CGFloat, dark: Bool) -> some View {
        let h = width * doc.canvasSize.height / max(doc.canvasSize.width, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high) } else { UI.bg }
            }
            .frame(width: width, height: h).clipShape(RoundedRectangle(cornerRadius: width > 200 ? 8 : 5))
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.75) : Color.black.opacity(0.7))
                .frame(width: width * 0.8, height: 6)
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color.white.opacity(0.35) : Color.black.opacity(0.3))
                .frame(width: width * 0.5, height: 5)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(dark ? Color(white: 0.06) : Color(white: 0.97)))
    }
}

private struct TileKey: Equatable { let scene: Scene; let width: Int; let theme: [String: JSONValue] }
private struct FeedKey: Equatable { let scene: Scene; let theme: [String: JSONValue] }
