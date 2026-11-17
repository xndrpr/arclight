import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// A picture of sound for agents, which see images but hear nothing: a spectrogram (what frequencies sound
/// when), a loudness curve, and optionally the clips as lanes and markers as lines, on one time axis.
public enum AudioSheet {
    public struct Lane: Sendable {
        public var label: String
        public var from: Double
        public var to: Double
        public var highlight: Bool
        public init(label: String, from: Double, to: Double, highlight: Bool = false) {
            self.label = label; self.from = from; self.to = to; self.highlight = highlight
        }
    }

    /// `start` is the time of the first sample (scene or file seconds), for the axis labels.
    public static func render(
        _ s: Stereo, start: Double = 0, lanes: [Lane] = [], marks: [(name: String, t: Double)] = [],
        phrases: [ClosedRange<Double>] = []
    ) throws -> CGImage {
        let W = 1400, left = 112, right = 12
        let specH = 240, loudH = 110, axisH = 22, laneH = 16
        let shown = Array(lanes.prefix(28))
        let H = specH + loudH + axisH + shown.count * laneH + (shown.isEmpty ? 0 : 8) + 8
        guard
            let ctx = CGContext(
                data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.readback }
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
        ctx.setFillColor(rgb(0.07, 0.07, 0.08))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        func label(_ t: String, x: CGFloat, y: CGFloat, color: CGColor = rgb(0.85, 0.85, 0.85)) {
            let attr = NSAttributedString(
                string: t,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        let plotW = W - left - right
        let dur = max(s.duration, 0.01)
        func x(_ t: Double) -> CGFloat { CGFloat(left) + CGFloat((t - start) / dur) * CGFloat(plotW) }
        // CG origin is bottom-left: lay the bands out from the top down.
        let specY = H - specH, loudY = specY - loudH, axisY = loudY - axisH

        // Spectrogram, log frequency 40 Hz – 18 kHz.
        let frame = 2048
        let mono = s.mono
        let fLo = 40.0, fHi = 18000.0
        if let dft = vDSP.DFT(count: frame, direction: .forward, transformType: .complexComplex, ofType: Float.self) {
            let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
            let zeros = [Float](repeating: 0, count: frame)
            let hz = Stereo.rate / Double(frame)
            // Row → bin range.
            let rowsBins: [(Int, Int)] = (0..<specH).map { row in
                let f0 = fLo * pow(fHi / fLo, Double(row) / Double(specH))
                let f1 = fLo * pow(fHi / fLo, Double(row + 1) / Double(specH))
                let a = max(1, Int(f0 / hz)), b = min(frame / 2 - 1, max(a, Int(f1 / hz)))
                return (a, b)
            }
            let colStep = 2
            for col in stride(from: 0, to: plotW, by: colStep) {
                let centre = Int(Double(col) / Double(plotW) * Double(mono.count))
                let a = centre - frame / 2
                var seg = [Float](repeating: 0, count: frame)
                for i in 0..<frame where a + i >= 0 && a + i < mono.count { seg[i] = mono[a + i] }
                var re = [Float](repeating: 0, count: frame), im = [Float](repeating: 0, count: frame)
                dft.transform(inputReal: vDSP.multiply(seg, window), inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
                for (row, (b0, b1)) in rowsBins.enumerated() {
                    var p: Float = 0
                    for b in b0...b1 { p = max(p, re[b] * re[b] + im[b] * im[b]) }
                    // dB relative to a full-scale sine in this window, −90…0 → 0…1.
                    let db = 10 * log10(Double(p) / Double(frame * frame / 16) + 1e-12)
                    let v = min(1, max(0, (db + 90) / 90))
                    guard v > 0.02 else { continue }
                    ctx.setFillColor(rgb(min(1, v * 2.2), max(0, v * 1.6 - 0.5), max(0.15 * v, 0.9 - abs(v - 0.35) * 3) * v + max(0, v - 0.85) * 4))
                    ctx.fill(CGRect(x: left + col, y: specY + row, width: colStep, height: 1))
                }
            }
            for f in [100.0, 1000, 5000, 10000] {
                let y = CGFloat(specY) + CGFloat(log(f / fLo) / log(fHi / fLo)) * CGFloat(specH)
                ctx.setFillColor(rgb(1, 1, 1, 0.18))
                ctx.fill(CGRect(x: CGFloat(left), y: y, width: CGFloat(plotW), height: 1))
                label(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", x: 6, y: y - 4)
            }
            label("Hz", x: 6, y: CGFloat(specY + specH - 14), color: rgb(0.6, 0.6, 0.6))
        }

        // Loudness curve (0.4 s windows), −60…0 LUFS, with speech phrases shaded behind it.
        ctx.setFillColor(rgb(0.11, 0.11, 0.13))
        ctx.fill(CGRect(x: left, y: loudY, width: plotW, height: loudH - 4))
        for ph in phrases {
            ctx.setFillColor(rgb(0.3, 0.6, 1, 0.22))
            ctx.fill(CGRect(x: x(ph.lowerBound), y: CGFloat(loudY), width: x(ph.upperBound) - x(ph.lowerBound), height: CGFloat(loudH - 4)))
        }
        func ly(_ db: Double) -> CGFloat { CGFloat(loudY) + CGFloat(min(1, max(0, (db + 60) / 60))) * CGFloat(loudH - 6) }
        for db in [-14.0, -30, -45] {
            ctx.setFillColor(rgb(1, 1, 1, 0.15))
            ctx.fill(CGRect(x: CGFloat(left), y: ly(db), width: CGFloat(plotW), height: 1))
            label("\(Int(db))", x: 6, y: ly(db) - 4)
        }
        label("LUFS", x: 6, y: CGFloat(loudY + loudH - 18), color: rgb(0.6, 0.6, 0.6))
        let curve = Loudness.windows(Loudness.kWeighted(s), window: 0.4)
        if curve.count > 1 {
            ctx.setStrokeColor(rgb(1, 0.8, 0.2))
            ctx.setLineWidth(1.5)
            ctx.beginPath()
            for (i, v) in curve.enumerated() {
                let p = CGPoint(x: x(start + 0.2 + Double(i) * 0.1), y: ly(v))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }

        // Time axis.
        let tick = dur <= 4 ? 0.25 : dur <= 12 ? 1.0 : dur <= 40 ? 2.0 : dur <= 120 ? 10.0 : 30.0
        var t = (start / tick).rounded(.up) * tick
        while t <= start + dur + 1e-6 {
            ctx.setFillColor(rgb(1, 1, 1, 0.12))
            ctx.fill(CGRect(x: x(t), y: CGFloat(axisY), width: 1, height: CGFloat(H - axisY)))
            label(Format.number((t * 100).rounded() / 100) + "s", x: x(t) + 3, y: CGFloat(axisY + 6))
            t += tick
        }
        for m in marks where m.t >= start && m.t <= start + dur {
            ctx.setFillColor(rgb(0.3, 1, 0.5, 0.7))
            ctx.fill(CGRect(x: x(m.t), y: CGFloat(axisY), width: 1, height: CGFloat(H - axisY)))
            label(m.name, x: x(m.t) + 3, y: CGFloat(H - 14), color: rgb(0.4, 1, 0.6))
        }

        // Clip lanes.
        for (i, lane) in shown.enumerated() {
            let y = CGFloat(axisY - 6 - (i + 1) * laneH)
            let a = x(max(start, lane.from)), b = x(min(start + dur, lane.to))
            ctx.setFillColor(lane.highlight ? rgb(0.3, 0.6, 1, 0.8) : rgb(1, 0.55, 0.2, 0.75))
            ctx.fill(CGRect(x: a, y: y + 2, width: max(2, b - a), height: CGFloat(laneH - 4)))
            label(String(lane.label.prefix(14)), x: 4, y: y + 3)
        }
        guard let out = ctx.makeImage() else { throw RenderError.readback }
        return out
    }
}
