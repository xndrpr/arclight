import ArclightCore
import MetalKit
import SwiftUI
import simd

/// Live Metal preview, letterboxed to the canvas aspect at Fit, with zoom/pan, guides, rulers and the
/// transform overlay. Zoom and pan live in `ViewportState` (view state, not the document).
struct ViewportView: View {
    @ObservedObject var doc: EditorDocument
    @StateObject private var vp = ViewportState()
    @State private var hint = true
    @State private var dropTarget = false
    @AppStorage(Pref.rulers) private var rulers = false

    var body: some View {
        GeometryReader { geo in
            let cs = doc.canvasSize
            let pad: CGFloat = doc.cinema ? 0 : (rulers ? 24 + CanvasRulers.thickness : 24)
            let fit = ViewZoom.fit(canvas: cs, view: geo.size, pad: pad)
            let s = doc.cinema ? fit : (vp.zoom ?? fit)
            let pan = doc.cinema ? .zero : vp.pan
            let size = CGSize(width: cs.width * s, height: cs.height * s)
            ZStack {
                ViewportAnchor(vp: vp)
                // Clicking the empty area around the canvas deselects (on press, so tap-to-click always lands).
                UI.bg.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { g in
                            guard ClickSlop.distance(g.translation) < ClickSlop.fastSlop else { return }
                            endEditing(); doc.multiSelection = []; doc.selection = nil
                        })
                ZStack {
                    MetalCanvas(doc: doc, pixelSize: MetalCanvas.drawableSize(for: size))
                    if !doc.cinema {
                        GuidesOverlay(canvas: cs, scale: s)
                        GizmoOverlay(doc: doc, vp: vp, scale: s)
                        FlashOverlay(doc: doc, scale: s)
                    }
                }
                .frame(width: size.width, height: size.height)
                .overlay(Rectangle().stroke(doc.cinema ? .clear : UI.border, lineWidth: 1))
                .position(x: geo.size.width / 2 + pan.width, y: geo.size.height / 2 + pan.height)
                if rulers && !doc.cinema { CanvasRulers(vp: vp) }
            }
            .onAppear { sync(geo.size, cs, pad) }
            .onChange(of: geo.size) { _, v in sync(v, cs, pad) }
            .onChange(of: cs) { _, v in sync(geo.size, v, pad) }
            .onChange(of: pad) { _, v in sync(geo.size, cs, v) }
        }
        .clipped()
        .background(UI.bg)
        .overlay { if dropTarget { DropTargetHint().allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers, location in drop(providers, at: location) }
        .overlay(alignment: .top) {
            if !doc.cinema {
                ViewerChrome(doc: doc, vp: vp)
                    .padding(.top, rulers ? CanvasRulers.thickness : 0).padding(
                        .leading, rulers ? CanvasRulers.thickness : 0)
            }
        }
        .overlay(alignment: .top) {
            if let t = doc.toast {
                Text(t).font(UI.small).foregroundStyle(UI.onAccent).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(UI.accent)).padding(.top, 44).padding(.horizontal, 16)
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if doc.isPastEnd && !doc.cinema {
                Text("Past the end — showing the last frame").font(UI.small).foregroundStyle(UI.text)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(UI.panel.opacity(0.92))).overlay(Capsule().stroke(UI.border))
                    .padding(.bottom, 12).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if doc.cinema && hint {
                Text("Space play · J K L shuttle · ← → frames · Esc exit").font(UI.small).foregroundStyle(UI.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(UI.panel.opacity(0.9)))
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withMotion(UI.fade) { hint = false } }
                    }
            }
        }
        .onChange(of: doc.cinema) { _, on in if on { hint = true } }
        .onChange(of: doc.scene.id) { _, _ in vp.fit() }
        .onAppear { vp.events.install(doc: doc, vp: vp) }
        .onDisappear { vp.events.remove() }
    }

    private func sync(_ view: CGSize, _ canvas: CGSize, _ pad: CGFloat) {
        vp.viewSize = view; vp.canvas = canvas; vp.pad = pad
    }

    /// Files from Finder: resolved on the main queue and imported at the canvas point under the drop.
    private func drop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        let c = vp.canvasPoint(location)
        let group = DispatchGroup()
        var urls: [Int: URL] = [:]
        let lock = NSLock()
        for (i, p) in providers.enumerated() where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u, u.isFileURL { lock.lock(); urls[i] = u; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let list = urls.keys.sorted().compactMap { urls[$0] }
            if !list.isEmpty { doc.dropFiles(list, at: c) }
        }
        return true
    }
}

/// Dashed outline and a hint while files are dragged over the viewer.
private struct DropTargetHint: View {
    var body: some View {
        ZStack {
            Rectangle().fill(UI.accent.opacity(0.06))
            Rectangle().strokeBorder(UI.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            Text("Drop to add images, audio or fonts").font(UI.small).foregroundStyle(UI.onAccent)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(UI.accent))
        }
        .padding(6)
    }
}
