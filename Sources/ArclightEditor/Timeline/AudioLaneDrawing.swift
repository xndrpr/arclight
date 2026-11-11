import AppKit
import ArclightCore
import SwiftUI

/// Clip box, waveform (scaled by the gain envelope), gain/fade line and handles.
struct AudioLaneDrawing {
    let clip: AudioClip
    let ref: AudioRef
    let peaks: [Float]?
    let map: TimeMap
    var gainLabel = false

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let c = clip
        let box = AudioLane.box(c, map, height: size.height)
        let muted = ref.mute == true
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(muted ? UI.field : UI.raised))
        // Waveform: one bar per pixel column, mirrored around the middle.
        if let peaks, !peaks.isEmpty, c.fileDuration > 0 {
            var wave = Path()
            let mid = box.midY, half = box.height / 2 - 1
            let x0 = max(0, box.minX), x1 = min(size.width, box.maxX)
            var x = floor(x0)
            let n = Double(peaks.count)
            while x < x1 {
                let ta = map.t(x), tb = map.t(x + 1)
                let fa = c.filePosition(at: ta), fb = c.filePosition(at: tb)
                let ia = max(0, Int(fa / c.fileDuration * n)), ib = min(peaks.count - 1, Int(fb / c.fileDuration * n))
                if ia <= ib, ia < peaks.count {
                    var pk: Float = 0
                    for i in ia...ib { pk = max(pk, peaks[i]) }
                    let env = ta >= c.sceneDuration ? c.gain : c.envelope(at: (ta + tb) / 2)
                    let h = min(half, CGFloat(Double(pk) * min(env, 2)) * half)
                    if h > 0.25 { wave.addRect(CGRect(x: x, y: mid - h, width: 1, height: h * 2)) }
                }
                x += 1
            }
            ctx.fill(wave, with: .color(muted ? UI.faint : UI.dim))
        }
        ctx.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(UI.fieldBorder), lineWidth: 1)
        ctx.draw(
            Text((ref.src as NSString).lastPathComponent).font(.system(size: 9.5, weight: .medium)).foregroundColor(
                UI.label2),
            at: CGPoint(x: max(box.minX, 0) + 5, y: box.minY + 7), anchor: .leading)
        // Gain envelope line: 0 at the audible start, ramps for the fades.
        let a = c.audibleStart, e = c.audibleEnd
        guard e > a else { return }
        var ts = [a, a + c.fadeIn, c.sceneDuration - c.fadeOut, e].filter { $0 >= a && $0 <= e }
        ts.sort()
        var line = Path()
        for (i, t) in ts.enumerated() {
            let g = c.envelope(at: t >= e ? e - 1e-6 : t)
            let p = CGPoint(x: map.x(t), y: AudioLane.gainY(g, height: size.height))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(UI.text.opacity(0.85)), lineWidth: 1.2)
        let gy = AudioLane.gainY(c.gain, height: size.height)
        for x in [map.x(a + c.fadeIn), map.x(max(a, min(e, c.sceneDuration - c.fadeOut)))] {
            let r = CGRect(x: x - 3.5, y: gy - 3.5, width: 7, height: 7)
            ctx.fill(Path(ellipseIn: r), with: .color(UI.text))
            ctx.stroke(Path(ellipseIn: r), with: .color(UI.panel), lineWidth: 1)
        }
        if gainLabel {
            ctx.draw(
                Text(AudioClip.dB(c.gain)).font(UI.monoSmall).foregroundColor(UI.text),
                at: CGPoint(x: max(box.minX, 0) + 5, y: max(gy - 8, box.minY + 18)), anchor: .leading)
        }
    }
}
