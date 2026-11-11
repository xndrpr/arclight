import AppKit
import SwiftUI

/// Themed colours and shared drawing for the ruler, audio lane and tracks (all `Canvas`-drawn), so every app
/// theme — light ones included — reads the same way.
enum TimelineInk {
    static var playhead: Color { UI.accent }
    static var endLine: Color { UI.label2 }
    static var rowLine: Color { UI.border.opacity(0.6) }
    static var bar: Color { UI.fieldBorder }
    static var barSelected: Color { UI.faint }
    static var barHidden: Color { UI.border }
    static var barStroke: Color { UI.faint.opacity(0.7) }
    static var key: Color { UI.label2 }
    static var propKey: Color { UI.text }
    /// Selected keyframes: one blue that reads on dark and light bars alike.
    static let selectedKey = Color(red: 0.25, green: 0.56, blue: 1.0)
    static var keyOutline: Color { UI.panel }
    static var boxFill: Color { UI.text.opacity(0.06) }
    static var boxStroke: Color { UI.text.opacity(0.7) }

    /// A vertical line of `width` centred exactly on `x` (the time's position). Ruler, audio lane and tracks all
    /// draw through this with the same `TimeMap`, so playhead, END, markers and ticks share one x.
    static func lineRect(_ x: CGFloat, y: CGFloat = 0, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x - width / 2, y: y, width: width, height: height)
    }

    /// The area after the scene's end: dimmed and hatched — "outside the scene, not rendered".
    static func drawPastEnd(_ ctx: GraphicsContext, _ size: CGSize, endX ex: CGFloat) {
        guard ex < size.width else { return }
        let x0 = max(ex, 0)
        let r = CGRect(x: x0, y: 0, width: size.width - x0, height: size.height)
        ctx.fill(Path(r), with: .color(UI.bg.opacity(UI.isDark ? 0.55 : 0.75)))
        var hatch = Path()
        let step: CGFloat = 7
        // Lines phase-locked to END so the ruler, audio lane and tracks line up while scrolling.
        var x = ex + ((x0 - ex) / step).rounded(.down) * step - size.height
        while x < size.width {
            hatch.move(to: CGPoint(x: x, y: size.height)); hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
            x += step
        }
        var c = ctx
        c.clip(to: Path(r))
        c.stroke(hatch, with: .color(UI.fieldBorder.opacity(UI.isDark ? 0.55 : 0.8)), lineWidth: 1)
    }

    static func drawEndLine(_ ctx: GraphicsContext, _ size: CGSize, endX ex: CGFloat) {
        ctx.fill(Path(lineRect(ex, width: 1, height: size.height)), with: .color(endLine))
    }

    static func drawPlayhead(_ ctx: GraphicsContext, _ size: CGSize, x px: CGFloat) {
        ctx.fill(Path(lineRect(px, width: 1.5, height: size.height)), with: .color(playhead))
    }
}
