import AppKit
import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// Tools of the Preview workspace (Figma letters first, Photoshop's where Figma has none).
enum PreviewTool: String, CaseIterable, Identifiable {
    case move, marquee, text, rect, ellipse, line, image, hand, zoom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: "Move"
        case .marquee: "Marquee (for generative fill)"
        case .text: "Text"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .image: "Place image"
        case .hand: "Hand"
        case .zoom: "Zoom"
        }
    }

    var key: String {
        switch self {
        case .move: "V"
        case .marquee: "M"
        case .text: "T"
        case .rect: "R"
        case .ellipse: "O"
        case .line: "L"
        case .image: "⇧⌘K"
        case .hand: "H"
        case .zoom: "Z"
        }
    }

    var symbol: String {
        switch self {
        case .move: "cursorarrow"
        case .marquee: "rectangle.dashed"
        case .text: "textformat"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .image: "photo"
        case .hand: "hand.raised"
        case .zoom: "plus.magnifyingglass"
        }
    }

    /// Tools that take over clicks and drags on the canvas (the move tool leaves them to the gizmos).
    var capturesCanvas: Bool { self != .move }
}

/// View commands for the board, sent from keys to the viewport that owns the zoom state.
enum BoardCommand: String {
    case actualSize, fitAll, fitArtboard, zoomIn, zoomOut
}

extension EditorDocument {
    /// Every artboard of the open page in board pixels relative to the open artboard (which sits at 0,0 in its own
    /// canvas pixels), with the open one using the working copy's size.
    func boardRects() -> [(artboard: Artboard, rect: CGRect)] {
        guard let p = openPreview, let aid = target.artboardId, let active = p.artboard(aid) else { return [] }
        return p.artboards.map { a in
            let size = a.id == aid ? canvasSize : CGSize(width: a.width, height: a.height)
            return (a, CGRect(x: a.x - active.x, y: a.y - active.y, width: size.width, height: size.height))
        }
    }

    func postBoard(_ c: BoardCommand) {
        NotificationCenter.default.post(name: .boardCommand, object: self, userInfo: ["cmd": c.rawValue])
    }

    /// Moves an artboard on the board by `d` canvas pixels.
    func moveArtboard(_ aid: String, by d: CGSize) {
        guard let pid = target.previewId, let a = store.previews[pid]?.artboard(aid) else { return }
        applyPage(
            pid,
            [["op": "artboard_set", "id": .string(aid), "x": .number((a.x + d.width).rounded()),
              "y": .number((a.y + d.height).rounded())]],
            summary: "move artboard \(aid)")
    }

    /// Creates a layer with a drawing tool from a dragged rectangle in canvas pixels (a click gives a default size).
    func createLayer(with tool: PreviewTool, from a: CGPoint, to b: CGPoint, square: Bool = false) {
        let m = Double(min(canvasSize.width, canvasSize.height))
        var w = Double(abs(b.x - a.x)), h = Double(abs(b.y - a.y))
        let clicked = w < 4 && h < 4
        if square { w = max(w, h); h = w }
        let x0 = Double(min(a.x, b.x)), y0 = Double(min(a.y, b.y))
        func r(_ v: Double) -> JSONValue { .number(v.rounded()) }
        switch tool {
        case .rect, .ellipse:
            if clicked { w = (m * 0.4).rounded(); h = tool == .ellipse ? w : (m * 0.25).rounded() }
            let cx = clicked ? Double(a.x) : x0 + w / 2, cy = clicked ? Double(a.y) : y0 + h / 2
            addNode(
                "shape",
                props: ["shape": tool == .rect ? "rect" : "ellipse", "x": r(cx), "y": r(cy), "width": r(w),
                        "height": r(h), "fill": "$accent"])
        case .line:
            let to: [JSONValue] = clicked ? [r(m * 0.4), 0] : [r(Double(b.x - a.x)), r(Double(b.y - a.y))]
            addNode(
                "shape",
                props: ["shape": "line", "x": r(Double(a.x)), "y": r(Double(a.y)), "to": .array(to),
                        "strokeWidth": 8, "stroke": "$fg", "cap": "round"])
        case .text:
            addNode(
                "text",
                props: ["text": "TEXT", "font": "$display", "size": r(m / 6), "color": "$fg", "x": r(Double(a.x)),
                        "y": r(Double(a.y))])
        default: return
        }
        self.tool = .move  // Figma: back to Move after drawing
    }
}

/// The vertical tool bar on the left of the Preview canvas.
struct PreviewToolBar: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        VStack(spacing: 2) {
            ForEach([PreviewTool.move, .marquee, .text, .rect, .ellipse, .line, .image], id: \.self) { button($0) }
            Hairline().frame(width: 18).padding(.vertical, 3)
            ArtboardToolMenu(doc: doc)
            Hairline().frame(width: 18).padding(.vertical, 3)
            ForEach([PreviewTool.hand, .zoom], id: \.self) { button($0) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.panel.opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UI.border))
        .fixedSize()
    }

    private func button(_ t: PreviewTool) -> some View {
        let on = doc.tool == t
        return Button {
            ClickTrace.fired("tool \(t.rawValue)")
            if t == .image { doc.placeImage(at: nil) } else { doc.tool = t }
        } label: {
            Image(systemName: t.symbol).font(.system(size: 13, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? UI.onAccent : UI.label2)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.accent : .clear))
                .hitArea()
        }
        .buttonStyle(TracedPlainButtonStyle(name: "tool \(t.rawValue)")).cursor(.pointingHand)
        .help("\(t.title) (\(t.key))")
    }
}

/// Artboard presets from the tool bar (A adds one like the open artboard).
private struct ArtboardToolMenu: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        Menu {
            Section("Add artboard") {
                ForEach(ArtboardPresets.all, id: \.self) { p in Button(p.title) { doc.addArtboard(preset: p) } }
            }
            if let a = doc.target.artboardId, let p = doc.target.previewId {
                Divider()
                Button("Duplicate as variant") { doc.duplicateArtboard(a, in: p) }
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 13)).foregroundStyle(UI.label2)
                .frame(width: 28, height: 26).hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 26)
        .help("Artboards: thumbnail, Shorts cover, square… (A adds one like this)").cursor(.pointingHand)
    }
}

/// Over the open canvas while a drawing, hand or zoom tool is active: turns clicks and drags into that tool's action.
struct PreviewToolOverlay: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var vp: ViewportState
    let scale: CGFloat
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var panStart: CGSize?

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in
                        switch doc.tool {
                        case .hand:
                            if panStart == nil { panStart = vp.pan }
                            vp.setPan(
                                CGSize(
                                    width: (panStart?.width ?? 0) + g.translation.width,
                                    height: (panStart?.height ?? 0) + g.translation.height))
                        default:
                            if start == nil { start = g.startLocation }
                            current = g.location
                        }
                    }
                    .onEnded { g in
                        defer { start = nil; current = nil; panStart = nil }
                        let a = ViewZoom.canvasPoint(g.startLocation, scale: scale)
                        let b = ViewZoom.canvasPoint(g.location, scale: scale)
                        let shift = NSEvent.modifierFlags.contains(.shift)
                        switch doc.tool {
                        case .hand: return
                        case .marquee:
                            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                            doc.marquee = r.width >= 4 && r.height >= 4 ? r.integral : nil
                            if doc.marquee != nil { doc.aiPrompt = .fill }
                        case .zoom:
                            let p = CGPoint(
                                x: vp.canvasOrigin.x + g.location.x, y: vp.canvasOrigin.y + g.location.y)
                            vp.zoom(by: NSEvent.modifierFlags.contains(.option) ? 0.5 : 2, at: p)
                        default:
                            doc.createLayer(with: doc.tool, from: a, to: b, square: shift)
                        }
                    }
            )
            .overlay {
                if let s = start, let c = current, [.rect, .ellipse, .line, .marquee].contains(doc.tool) {
                    Path { p in
                        if doc.tool == .line {
                            p.move(to: s); p.addLine(to: c)
                        } else if doc.tool == .ellipse {
                            p.addEllipse(in: CGRect(origin: s, size: CGSize(width: c.x - s.x, height: c.y - s.y)))
                        } else {
                            p.addRect(CGRect(origin: s, size: CGSize(width: c.x - s.x, height: c.y - s.y)))
                        }
                    }
                    .stroke(UI.accent, lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .cursor(doc.tool == .hand ? .openHand : doc.tool == .text ? .iBeam : .crosshair)
    }
}

extension EditorDocument {
    /// ⌥⌘] / ⌥⌘[: the selected layer to the top or bottom of its siblings' draw order.
    func arrange(toFront: Bool) {
        guard let id = selection, let n = scene.node(id) else { return }
        let siblings = scene.nodes.filter { $0.parent == n.parent && $0.id != id }
        guard let edge = toFront ? siblings.last : siblings.first else { return }
        apply([["op": "move", "id": .string(id), toFront ? "after" : "before": .string(edge.id)]])
    }

    /// ⇧⌘K / the image tool: pick image files and place them centred on `point` (default: the canvas centre).
    func placeImage(at point: CGPoint?) {
        let urls = FilePicker.files([.image], multiple: true)
        guard !urls.isEmpty else { return }
        dropFiles(urls, at: point ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        tool = .move
    }
}

/// Hand tool (H, or held Space) over the whole viewer: drag anywhere to pan the board.
struct HandPanOverlay: View {
    @ObservedObject var vp: ViewportState
    @State private var start: CGSize?

    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil { start = vp.pan }
                        vp.setPan(
                            CGSize(
                                width: (start?.width ?? 0) + g.translation.width,
                                height: (start?.height ?? 0) + g.translation.height))
                    }
                    .onEnded { _ in start = nil }
            )
            .cursor(.openHand)
    }
}
