import SwiftUI

/// Centre lines, title/action safe areas and rule of thirds, drawn over the canvas (no hit testing).
struct GuidesOverlay: View {
    let canvas: CGSize
    let scale: CGFloat
    @AppStorage(Pref.centerLines) private var center = false
    @AppStorage(Pref.safeAreas) private var safe = false
    @AppStorage(Pref.thirds) private var thirds = false

    var body: some View {
        SwiftUI.Canvas { ctx, _ in
            let s = scale, w = canvas.width * s, h = canvas.height * s
            // Light line over a faint dark halo: readable on any video content.
            let line = GraphicsContext.Shading.color(.white.opacity(0.45))
            let halo = GraphicsContext.Shading.color(.black.opacity(0.3))
            func seg(_ a: CGPoint, _ b: CGPoint, dash: [CGFloat] = []) {
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: halo, style: StrokeStyle(lineWidth: 2.5, dash: dash))
                ctx.stroke(p, with: line, style: StrokeStyle(lineWidth: 1, dash: dash))
            }
            if thirds {
                let t = CanvasGuides.thirds(canvas)
                for x in t.xs { seg(CGPoint(x: x * s, y: 0), CGPoint(x: x * s, y: h)) }
                for y in t.ys { seg(CGPoint(x: 0, y: y * s), CGPoint(x: w, y: y * s)) }
            }
            if center {
                seg(CGPoint(x: w / 2, y: 0), CGPoint(x: w / 2, y: h), dash: [6, 4])
                seg(CGPoint(x: 0, y: h / 2), CGPoint(x: w, y: h / 2), dash: [6, 4])
            }
            if safe {
                for f in [CanvasGuides.actionSafe, CanvasGuides.titleSafe] {
                    let r = CanvasGuides.safe(canvas, fraction: f)
                    let rect = Path(CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s))
                    let dash: [CGFloat] = f == CanvasGuides.titleSafe ? [2, 3] : []
                    ctx.stroke(rect, with: halo, style: StrokeStyle(lineWidth: 2.5, dash: dash))
                    ctx.stroke(rect, with: line, style: StrokeStyle(lineWidth: 1, dash: dash))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pixel rulers along the top and left edges of the viewer, following zoom and pan.
struct CanvasRulers: View {
    @ObservedObject var vp: ViewportState
    static let thickness: CGFloat = 16

    var body: some View {
        SwiftUI.Canvas { ctx, size in
            let s = vp.scale, o = vp.canvasOrigin, t = Self.thickness
            let step = RulerMath.step(scale: s)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: t)), with: .color(UI.panel))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: t, height: size.height)), with: .color(UI.panel))
            let tick = GraphicsContext.Shading.color(UI.faint)
            // Canvas extent highlight.
            let cw = vp.canvas.width * s, ch = vp.canvas.height * s
            ctx.fill(Path(CGRect(x: o.x, y: t - 2, width: cw, height: 2)), with: .color(UI.border))
            ctx.fill(Path(CGRect(x: t - 2, y: o.y, width: 2, height: ch)), with: .color(UI.border))
            for v in RulerMath.ticks(from: (t - o.x) / s, to: (size.width - o.x) / s, step: step) {
                let x = o.x + v * s
                var p = Path(); p.move(to: CGPoint(x: x, y: t / 2)); p.addLine(to: CGPoint(x: x, y: t))
                ctx.stroke(p, with: tick, lineWidth: 1)
                ctx.draw(
                    Text(fmt(Double(v))).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(UI.dim),
                    at: CGPoint(x: x + 2, y: 1), anchor: .topLeading)
            }
            for v in RulerMath.ticks(from: (t - o.y) / s, to: (size.height - o.y) / s, step: step) {
                let y = o.y + v * s
                var p = Path(); p.move(to: CGPoint(x: t / 2, y: y)); p.addLine(to: CGPoint(x: t, y: y))
                ctx.stroke(p, with: tick, lineWidth: 1)
                var c = ctx
                c.translateBy(x: 1, y: y - 2)
                c.rotate(by: .degrees(-90))
                c.draw(
                    Text(fmt(Double(v))).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(UI.dim),
                    at: .zero, anchor: .topLeading)
            }
            ctx.fill(Path(CGRect(x: 0, y: 0, width: t, height: t)), with: .color(UI.panel))
            ctx.stroke(
                Path(CGRect(x: 0, y: t - 0.5, width: size.width, height: 0)), with: .color(UI.border), lineWidth: 1)
            ctx.stroke(
                Path(CGRect(x: t - 0.5, y: 0, width: 0, height: size.height)), with: .color(UI.border), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
