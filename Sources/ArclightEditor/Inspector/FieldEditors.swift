import ArclightCore
import SwiftUI

/// The value editor for a field kind.
struct FieldEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    @Binding var exprOpen: Bool

    var body: some View {
        if let e = slot.expr {
            ExprField(doc: doc, slot: slot, source: e, open: $exprOpen)
        } else {
            editor.defaulted(!slot.isSet)
        }
    }

    @ViewBuilder private var editor: some View {
        switch slot.field.kind {
        case .number, .integer: NumberEditor(doc: doc, slot: slot)
        case .bool:
            HStack {
                SwitchField(value: slot.shown?.bool ?? false) { doc.write(slot, .bool($0)) }; Spacer(minLength: 0)
            }
        case .color:
            ColorField(doc: doc, value: slot.shown?.string ?? "") { doc.write(slot, .string($0)) }
        case .paint: PaintField(doc: doc, slot: slot)
        case .string(let multiline):
            TextCommitField(text: slot.shown?.string ?? "", mono: !multiline, multiline: multiline) {
                doc.write(slot, .string($0))
            }
        case .font: FontField(doc: doc, slot: slot)
        case .choice(let options): ChoiceEditor(doc: doc, slot: slot, options: options)
        case .vector(let labels, _): VectorEditor(doc: doc, slot: slot, labels: labels)
        case .numberOrVector(let labels): NumberOrVectorEditor(doc: doc, slot: slot, labels: labels)
        case .easing: EasingField(value: slot.shown) { doc.write(slot, $0) }
        case .asset(let kind): AssetField(doc: doc, slot: slot, kind: kind)
        case .symbol: SymbolField(doc: doc, value: slot.shown?.string) { doc.write(slot, .string($0)) }
        case .json, .object, .list, .numberOrObject: JSONEditor(doc: doc, slot: slot)
        }
    }
}

private struct NumberEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot

    var body: some View {
        let info = slot.field.numberInfo
        let text = slot.shown.map { $0.double.map(fmt) ?? $0.string ?? $0.compactString } ?? ""
        let emphasized = slot.rootAnimated || slot.keyedInside
        HStack(spacing: 6) {
            if case .integer(let lo, let hi) = slot.field.kind {
                StepperField(value: Int(slot.shown?.double ?? 0), min: lo, max: hi, emphasized: emphasized) {
                    doc.write(slot, .number(Double($0)))
                }
            } else {
                TextCommitField(text: text, mono: true, placeholder: "—", emphasized: emphasized) {
                    commit($0, info)
                }
                .frame(width: hasSlider(info) ? 62 : nil)
                if let u = info?.unit { Text(u).font(UI.monoSmall).foregroundStyle(UI.faint).fixedSize() }
                if hasSlider(info), let lo = info?.min, let hi = info?.max {
                    ThinSlider(value: slot.shown?.double ?? lo, range: lo...hi, step: info?.step ?? 0.01) { v, phase in
                        doc.scrub(slot, v, phase)
                    }
                }
            }
        }
        .readOnlyWhenKeyedInside(slot)
    }

    private func hasSlider(_ i: (min: Double?, max: Double?, step: Double, unit: String?)?) -> Bool {
        guard let i, i.min != nil, i.max != nil else { return false }
        if case .integer = slot.field.kind { return false }
        return true
    }

    private func commit(_ s: String, _ info: (min: Double?, max: Double?, step: Double, unit: String?)?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { doc.write(slot, nil); return }
        if t.hasPrefix("$") { doc.write(slot, .string(t)); return }
        guard let d = Double(t.replacingOccurrences(of: ",", with: ".")) else { return }
        doc.write(slot, .number(clamp(d, info?.min, info?.max)))
    }
}

extension View {
    /// A number keyframed inside an object setting shows its value at the playhead but can't be typed or dragged
    /// (that would replace its keyframes with one number); its object's "Edit as JSON…" changes it.
    @ViewBuilder func readOnlyWhenKeyedInside(_ s: Slot) -> some View {
        if s.keyedInside {
            disabled(true).help(
                "Keyframed: the value at the playhead. Change its keys with Edit as JSON… in the \(s.root) menu.")
        } else {
            self
        }
    }
}

private struct ChoiceEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let options: [String]
    var body: some View {
        let v = slot.shown?.string
        // Segments only when every label fits; otherwise a dropdown.
        if options.count <= 3 && options.map(\.count).reduce(0, +) <= 18 {
            SegmentedChoice(value: v, options: options) { doc.write(slot, .string($0)) }
        } else {
            ChoiceField(value: v ?? "—", options: options) { doc.write(slot, .string($0)) }
        }
    }
}

private struct VectorEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let labels: [String]
    var body: some View {
        let vals = slot.shown?.doubles ?? []
        func set(_ i: Int, _ d: Double) {
            var a = vals.count == labels.count ? vals : Array(repeating: 0.0, count: labels.count)
            for k in vals.indices where k < a.count { a[k] = vals[k] }
            a[i] = d
            doc.write(slot, .array(a.map { .number($0) }))
        }
        return VectorFields(
            labels: labels, values: vals, emphasized: slot.rootAnimated,
            scrubStep: vectorScrubStep(slot, vals), scrub: vectorScrub(doc, slot, set), commit: set)
    }
}

/// Per-pixel change when dragging a vector's axis letter: a pixel per pixel for px fields, finer for small values
/// (scale, trim 0–1).
func vectorScrubStep(_ s: Slot, _ values: [Double]) -> Double {
    if case .vector(_, let unit?) = s.field.kind, unit == "px" { return 1 }
    return values.allSatisfy { abs($0) <= 10 } ? 0.01 : 1
}

/// Scrub handler for one vector component: one undo step per drag, nil when the slot can't be scrubbed.
func vectorScrub(
    _ doc: EditorDocument, _ s: Slot, _ set: @escaping (Int, Double) -> Void
) -> ((Int, Double, ScrubLabel.Phase) -> Void)? {
    guard s.expr == nil, s.shown?.string?.hasPrefix("$") != true else { return nil }
    return { i, v, phase in
        switch phase {
        case .began: doc.beginGesture()
        case .changed: set(i, v)
        case .ended: doc.endGesture()
        }
    }
}

/// A number, or one value per axis; the link toggles between them.
private struct NumberOrVectorEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let labels: [String]
    var body: some View {
        let arr = slot.shown?.doubles
        HStack(spacing: 4) {
            if let arr, slot.shown?.array != nil {
                let set: (Int, Double) -> Void = { i, d in
                    var a = arr; while a.count < labels.count { a.append(a.last ?? 1) }
                    a[i] = d
                    doc.write(slot, .array(a.map { .number($0) }))
                }
                VectorFields(
                    labels: labels, values: arr, emphasized: slot.rootAnimated,
                    scrubStep: vectorScrubStep(slot, arr), scrub: vectorScrub(doc, slot, set), commit: set)
            } else {
                NumberEditor(doc: doc, slot: slot)
            }
            link(uniform: slot.shown?.array == nil, arr: arr)
        }
    }

    private func link(uniform: Bool, arr: [Double]?) -> some View {
        Button {
            if uniform {
                let v = slot.shown?.double ?? 1
                doc.write(slot, .array(labels.map { _ in .number(v) }))
            } else {
                doc.write(slot, .number(arr?.first ?? 1))
            }
        } label: {
            Image(systemName: uniform ? "link" : "link.badge.plus").font(.system(size: 10)).foregroundStyle(
                uniform ? UI.label2 : UI.faint
            )
            .frame(width: 18, height: 22).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        .help(uniform ? "Uniform — click to set each axis separately" : "Per axis — click to use one value for all")
    }
}

/// Raw JSON for fields without a dedicated editor.
private struct JSONEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    var body: some View {
        CodeField(title: slot.field.label, text: slot.shown.map(prettyJSON) ?? "", badge: "{ }") { str in
            if str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { doc.write(slot, nil); return nil }
            guard let j = JSONValue.parse(str) else { return "Not valid JSON" }
            doc.write(slot, j); return nil
        }
    }
}

func prettyJSON(_ v: JSONValue) -> String {
    (try? String(data: JSONFormat.pretty().encode(v), encoding: .utf8)) ?? v.compactString
}
