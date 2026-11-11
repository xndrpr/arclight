import AppKit
import SwiftUI

/// Label that scrubs a number when dragged horizontally (⇧ = ×10, ⌥ = ×0.1).
struct ScrubLabel: View {
    enum Phase { case began, changed, ended }
    let text: String
    let value: Double?
    let fine: Bool
    let enabled: Bool
    var animated = false
    /// Change per dragged pixel (overrides `fine`); results are rounded to it.
    var step: Double? = nil
    var width: CGFloat = UI.labelWidth
    var dimmed = false
    var doc = ""
    /// Axis letter of a vector field (x / y / z): small and faint.
    var axis = false
    let onScrub: (Double, Phase) -> Void
    @State private var start: Double?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(axis ? .system(size: 9.5, weight: .medium) : UI.small)
                .foregroundStyle(axis ? UI.faint : dimmed ? UI.dim : UI.label2).lineLimit(1).truncationMode(.tail)
            if animated { Circle().fill(UI.accent.opacity(0.8)).frame(width: 4, height: 4) }
        }
        .fixedSize(horizontal: axis, vertical: false)
        .frame(width: axis ? nil : width, alignment: .leading)
        .frame(minHeight: axis ? 22 : nil)
        .hitArea()
        .cursor(enabled ? .resizeLeftRight : .arrow)
        .help(
            enabled
                ? (doc.isEmpty ? "" : doc + "\n") + "Drag to change · ⇧ faster · ⌥ finer" : (doc.isEmpty ? text : doc)
        )
        .gesture(
            DragGesture(minimumDistance: 2).onChanged { g in
                guard enabled, let v = value else { return }
                // Leaving a focused field first, so it shows the live value (its typed text, if any, commits now).
                if start == nil { endEditing(); start = v; onScrub(v, .began) }
                var step = self.step ?? (fine ? 0.005 : 1)
                let m = NSEvent.modifierFlags
                if m.contains(.shift) { step *= 10 }
                if m.contains(.option) { step *= 0.1 }
                var nv = start! + Double(g.translation.width) * step
                if self.step != nil {
                    let q = min(1, step)  // keep precision of the step
                    nv = (nv / q).rounded() * q
                    nv = rounded(nv, places: 4)
                } else {
                    nv = rounded(nv, places: fine ? 3 : 1)
                }
                onScrub(nv, .changed)
            }.onEnded { _ in
                if start != nil { onScrub(value ?? 0, .ended) }; start = nil
            })
    }
}

/// Thin slider in the house style (white fill on a hairline track).
struct ThinSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let onChange: (Double, ScrubLabel.Phase) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            let u = CGFloat(
                (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                    / max(range.upperBound - range.lowerBound, 1e-9))
            ZStack(alignment: .leading) {
                Capsule().fill(UI.fieldBorder).frame(height: 2)
                Capsule().fill(UI.label2).frame(width: u * w, height: 2)
                Circle().fill(UI.text).overlay(Circle().stroke(UI.panel, lineWidth: 1)).frame(width: 10, height: 10)
                    .offset(x: u * w - 5)
            }
            .frame(maxHeight: .infinity)
            .hitArea()
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { d in
                    if !dragging { endEditing(); dragging = true; onChange(value, .began) }
                    let f = min(max(d.location.x / w, 0), 1)
                    var v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    v = (v / step).rounded() * step
                    onChange(rounded(v, places: 4), .changed)
                }.onEnded { _ in
                    dragging = false; onChange(value, .ended)
                })
        }
        .frame(height: 26)
        .cursor(.pointingHand)
    }
}

/// Row of small labelled number fields (x / y / z).
struct VectorFields: View {
    let labels: [String]
    let values: [Double]
    var emphasized = false
    var dimmed = false
    /// Drag the axis letters to scrub one component (change per pixel); nil = plain labels.
    var scrubStep: Double? = nil
    var scrub: ((Int, Double, ScrubLabel.Phase) -> Void)? = nil
    let commit: (Int, Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                HStack(spacing: 3) {
                    if let scrub, i < values.count {
                        ScrubLabel(
                            text: l, value: values[i], fine: false, enabled: true, step: scrubStep ?? 1, axis: true
                        ) { v, phase in
                            scrub(i, v, phase)
                        }
                    } else {
                        Text(l).font(.system(size: 9.5, weight: .medium)).foregroundStyle(UI.faint).fixedSize()
                    }
                    TextCommitField(
                        text: i < values.count ? fmt(values[i]) : "", mono: true, placeholder: "—",
                        emphasized: emphasized
                    ) { s in
                        if let d = Double(s.trimmingCharacters(in: .whitespaces)) { commit(i, d) }
                    }
                    .opacity(dimmed ? 0.55 : 1)
                }
            }
        }
    }
}
