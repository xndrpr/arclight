import ArclightCore
import Combine
import MetalKit
import SwiftUI

struct MetalCanvas: NSViewRepresentable {
    @ObservedObject var doc: EditorDocument
    /// Drawable size in pixels (capped so deep zoom doesn't allocate huge textures; the layer scales it up).
    var pixelSize: CGSize = .zero

    private static let maxPixels: CGFloat = 8192

    /// `playing`: the scene's size in px while it plays — more pixels than the film has only cost frame time.
    static func drawableSize(
        for points: CGSize, backing: CGFloat = NSScreen.main?.backingScaleFactor ?? 2, playing scene: CGSize? = nil
    ) -> CGSize {
        let w = points.width * backing, h = points.height * backing
        var k = min(1, maxPixels / max(w, h, 1))
        if let scene, scene.width > 1 { k = min(k, scene.width / max(w, 1)) }
        return CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: doc.renderer.device)
        v.colorPixelFormat = Renderer.outFormat
        v.framebufferOnly = true
        v.clearColor = MetalCanvas.clearColor
        v.preferredFramesPerSecond = 60
        v.delegate = context.coordinator
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.autoResizeDrawable = false
        v.layerContentsPlacement = .scaleAxesIndependently
        if pixelSize.width > 1 { v.drawableSize = pixelSize }
        context.coordinator.observeTheme(v)
        context.coordinator.observeOptions(v)
        return v
    }

    /// Clear colour behind the frame (only visible while a resize catches up): the app theme's background.
    static var clearColor: MTLClearColor {
        let c = NSColor(UI.bg).usingColorSpace(.sRGB) ?? .black
        return MTLClearColor(
            red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: 1)
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.doc = doc
        v.clearColor = Self.clearColor
        if pixelSize.width > 1, v.drawableSize != pixelSize { v.drawableSize = pixelSize; v.needsDisplay = true }
        // No more frames than the scene has (a 30 fps scene on a 120 Hz screen would be drawn four times over).
        let fps = min(60, max(12, Int(doc.fps.rounded())))
        if v.preferredFramesPerSecond != fps { v.preferredFramesPerSecond = fps }
        v.isPaused = !doc.playing
        v.enableSetNeedsDisplay = !doc.playing
        if !doc.playing { v.needsDisplay = true }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var doc: EditorDocument
        private var themeToken: NSObjectProtocol?
        init(doc: EditorDocument) { self.doc = doc }
        deinit { if let t = themeToken { NotificationCenter.default.removeObserver(t) } }

        /// The clear colour is a fixed Metal value: refresh it (and redraw) when the app theme changes.
        func observeTheme(_ v: MTKView) {
            themeToken = NotificationCenter.default.addObserver(forName: .appThemeChanged, object: nil, queue: .main) {
                [weak v] _ in
                guard let v else { return }
                v.clearColor = MetalCanvas.clearColor
                v.needsDisplay = true
            }
        }

        private var optionsToken: AnyCancellable?

        /// Performance mode changes how the viewer renders: draw again (it isn't part of the document's changes).
        func observeOptions(_ v: MTKView) {
            optionsToken = doc.view.objectWillChange.sink { [weak v] _ in
                DispatchQueue.main.async { v?.needsDisplay = true }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            // Tick before asking for a drawable: a frame without one must not hold the playhead still.
            let t = doc.playing ? doc.tick() : doc.viewTime  // past END: hold the last frame
            guard let drawable = view.currentDrawable, let cb = doc.renderer.queue.makeCommandBuffer() else { return }
            doc.renderer.draft = true  // motion blur only at export
            doc.renderer.only = doc.soloIds.isEmpty ? nil : doc.soloIds
            doc.renderer.encodePreview(
                scene: doc.scene, project: doc.project, assets: doc.assets, time: t,
                drawable: drawable.texture, resolution: doc.performance ? 0.5 : 1, commandBuffer: cb)
            cb.present(drawable)
            cb.commit()
        }
    }
}
