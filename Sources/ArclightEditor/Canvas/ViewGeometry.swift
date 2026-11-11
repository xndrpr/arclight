import CoreGraphics
import Foundation

// Pure view geometry for the canvas: zoom/pan, rulers, guides, snapping, selection, dropped files.

// MARK: Zoom & pan

enum ViewZoom {
    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 8
    static let presets: [CGFloat] = [0.5, 1, 2]

    /// Scale that letterboxes `canvas` into `view` minus `pad` on each side.
    static func fit(canvas: CGSize, view: CGSize, pad: CGFloat) -> CGFloat {
        let w = max(view.width - pad * 2, 10), h = max(view.height - pad * 2, 10)
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min(w / canvas.width, h / canvas.height)
    }

    /// Clamps to the zoom limits, widened to include `fit`: a tiny canvas fits above 8× and a huge one below 5 %,
    /// and zooming from Fit must never jump the other way.
    static func clamp(_ s: CGFloat, fit: CGFloat? = nil) -> CGFloat {
        min(max(s, min(minScale, fit ?? minScale)), max(maxScale, fit ?? maxScale))
    }

    /// New pan so the canvas point under `pointer` stays put when the scale goes `s0` → `s1`.
    /// `pointer` and `pan` are relative to the viewport centre (pan = canvas centre offset).
    static func pan(zoomingFrom s0: CGFloat, to s1: CGFloat, at pointer: CGPoint, pan: CGSize) -> CGSize {
        guard s0 > 0 else { return pan }
        let k = s1 / s0
        return CGSize(width: pointer.x - (pointer.x - pan.width) * k, height: pointer.y - (pointer.y - pan.height) * k)
    }

    /// Keeps at least `margin` points of the canvas inside the viewport.
    static func clampPan(_ pan: CGSize, canvas: CGSize, view: CGSize, margin: CGFloat = 40) -> CGSize {
        let lx = max(0, (view.width + canvas.width) / 2 - margin),
            ly = max(0, (view.height + canvas.height) / 2 - margin)
        return CGSize(width: min(max(pan.width, -lx), lx), height: min(max(pan.height, -ly), ly))
    }

    /// Top-left of the canvas in viewport coordinates.
    static func canvasOrigin(view: CGSize, canvas: CGSize, scale s: CGFloat, pan: CGSize) -> CGPoint {
        CGPoint(
            x: view.width / 2 + pan.width - canvas.width * s / 2,
            y: view.height / 2 + pan.height - canvas.height * s / 2)
    }

    /// Canvas pixel under a viewport point (viewport origin top-left).
    static func canvasPoint(_ p: CGPoint, view: CGSize, canvas: CGSize, scale s: CGFloat, pan: CGSize) -> CGPoint {
        let o = canvasOrigin(view: view, canvas: canvas, scale: s, pan: pan)
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    /// Canvas pixel under a point given in canvas-view points (the canvas's own top-left origin).
    static func canvasPoint(_ p: CGPoint, scale s: CGFloat) -> CGPoint { CGPoint(x: p.x / s, y: p.y / s) }

    static func label(_ s: CGFloat) -> String { "\(Int((s * 100).rounded()))%" }
}

// MARK: Rulers

enum RulerMath {
    /// A 1/2/5 × 10ⁿ canvas-pixel step whose on-screen spacing is at least `minPoints`.
    static func step(scale s: CGFloat, minPoints: CGFloat = 60) -> CGFloat {
        guard s > 0 else { return 100 }
        let raw = minPoints / s
        let p = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] as [CGFloat] where p * m >= raw { return p * m }
        return p * 10
    }

    /// Tick values (canvas px) visible between `lo` and `hi`.
    static func ticks(from lo: CGFloat, to hi: CGFloat, step: CGFloat) -> [CGFloat] {
        guard step > 0, hi > lo, (hi - lo) / step < 2000 else { return [] }
        var v = (lo / step).rounded(.up) * step, out: [CGFloat] = []
        while v <= hi { out.append(v); v += step }
        return out
    }
}

// MARK: Guides

enum CanvasGuides {
    /// Centred safe-area rectangle covering `fraction` of the canvas (broadcast: action safe 90%, title safe 80%).
    static func safe(_ canvas: CGSize, fraction f: CGFloat) -> CGRect {
        let w = canvas.width * f, h = canvas.height * f
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }
    static let actionSafe: CGFloat = 0.9
    static let titleSafe: CGFloat = 0.8

    static func thirds(_ canvas: CGSize) -> (xs: [CGFloat], ys: [CGFloat]) {
        ([canvas.width / 3, canvas.width * 2 / 3], [canvas.height / 3, canvas.height * 2 / 3])
    }
}

// MARK: Snapping

struct SnapLine: Equatable, Hashable {
    enum Axis { case x, y }
    let axis: Axis
    let value: CGFloat
}

enum Snap {
    /// Snap target lines: canvas edges, centre and safe areas, plus every other layer's edges and centre.
    static func targets(canvas: CGSize, others: [CGRect], safeAreas: Bool = true) -> (xs: [CGFloat], ys: [CGFloat]) {
        var xs: [CGFloat] = [0, canvas.width / 2, canvas.width], ys: [CGFloat] = [0, canvas.height / 2, canvas.height]
        if safeAreas {
            for f in [CanvasGuides.actionSafe, CanvasGuides.titleSafe] {
                let r = CanvasGuides.safe(canvas, fraction: f)
                xs += [r.minX, r.maxX]; ys += [r.minY, r.maxY]
            }
        }
        for r in others { xs += [r.minX, r.midX, r.maxX]; ys += [r.minY, r.midY, r.maxY] }
        return (xs, ys)
    }

    /// Best offset (≤ `threshold`) bringing any of `probes` onto any of `targets`, and the target hit.
    static func best(_ probes: [CGFloat], _ targets: [CGFloat], threshold: CGFloat) -> (delta: CGFloat, at: CGFloat)? {
        var best: (CGFloat, CGFloat)?
        for p in probes {
            for t in targets {
                let d = t - p
                if abs(d) <= threshold, abs(d) < abs(best?.0 ?? .infinity) { best = (d, t) }
            }
        }
        return best
    }

    /// Snaps a moving rectangle (edges + centre). Returns the corrected rect origin offset and lines to draw.
    static func snap(
        _ r: CGRect, xs: [CGFloat], ys: [CGFloat], threshold: CGFloat
    ) -> (offset: CGSize, lines: [SnapLine]) {
        var off = CGSize.zero, lines: [SnapLine] = []
        if let b = best([r.minX, r.midX, r.maxX], xs, threshold: threshold) {
            off.width = b.delta; lines.append(SnapLine(axis: .x, value: b.at))
        }
        if let b = best([r.minY, r.midY, r.maxY], ys, threshold: threshold) {
            off.height = b.delta; lines.append(SnapLine(axis: .y, value: b.at))
        }
        return (off, lines)
    }
}

// MARK: Selection

enum CanvasSelection {
    /// ⇧-click: toggles `id` in (primary, extras). Adding makes it primary; removing the primary promotes another.
    static func toggle(_ id: String, primary: String?, extras: Set<String>) -> (primary: String?, extras: Set<String>) {
        var all = extras.union(primary.map { [$0] } ?? [])
        if all.contains(id) {
            all.remove(id)
            let p = primary == id ? all.sorted().last : primary
            return (p, all.subtracting(p.map { [$0] } ?? []))
        }
        return (id, all)
    }
}

// MARK: Dropped files

enum DropKind: Equatable {
    case image, audio, font, svg, unsupported

    static func of(_ url: URL) -> DropKind {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp": return .image
        case "wav", "aif", "aiff", "mp3", "m4a": return .audio
        case "ttf", "otf", "ttc": return .font
        case "svg": return .svg
        default: return .unsupported
        }
    }
}
