import ArclightCore
import SwiftUI

/// One schema field: picks a scalar row, an object sub-section or a list editor by kind.
struct FieldRow: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot

    var body: some View {
        switch slot.field.kind {
        case .object(let o):
            ObjectSection(doc: doc, slot: slot, schema: o)
        case .numberOrObject(let o):
            if slot.stored?.object != nil {
                ObjectSection(doc: doc, slot: slot, schema: o, shorthand: true)
            } else {
                ShorthandRow(doc: doc, slot: slot, schema: o)
            }
        case .list(let o):
            ListSection(doc: doc, slot: slot, schema: o)
        default:
            ScalarRow(doc: doc, slot: slot)
        }
    }
}

/// Fields that render their editor under the label (wide editors).
private func stacked(_ s: Slot) -> Bool {
    if s.expr != nil { return false }
    switch s.field.kind {
    case .vector(let l, _): return l.count >= 3 || (s.keyable && s.rootAnimated)
    case .numberOrVector(let l): return s.shown?.array != nil && l.count >= 3
    case .paint: return s.shown?.object != nil
    case .string(let multiline): return multiline
    default: return false
    }
}

/// label · editor · keyframe controls · ƒx · options.
private struct ScalarRow: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    var extra: AnyView? = nil
    @State private var exprOpen = false
    @Environment(\.inspectorIndent) private var indent

    var body: some View {
        if stacked(slot) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    label; Spacer(minLength: 0); trailing
                }
                FieldEditor(doc: doc, slot: slot, exprOpen: $exprOpen)
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                label.frame(minHeight: UI.rowHeight)
                FieldEditor(doc: doc, slot: slot, exprOpen: $exprOpen).frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
        }
    }

    private var label: some View {
        let num = slot.field.numberInfo
        let value = slot.shown?.double
        return ScrubLabel(
            text: slot.field.label, value: value, fine: (num?.step ?? 1) < 1,
            enabled: num != nil && slot.expr == nil && value != nil && slot.shown?.string?.hasPrefix("$") != true
                && !slot.keyedInside,
            animated: slot.rootAnimated || slot.expr != nil || slot.keyedInside,
            step: num.map { scrubStep($0.step, $0.min, $0.max) },
            width: max(48, UI.labelWidth - indent), dimmed: !slot.isSet, doc: slot.field.doc
        ) { v, phase in
            doc.scrub(slot, clamp(v, num?.min, num?.max), phase)
        }
    }

    private var trailing: some View {
        RowTrailing(doc: doc, slot: slot, exprOpen: $exprOpen, extra: extra)
    }
}

func clamp(_ v: Double, _ lo: Double?, _ hi: Double?) -> Double { min(hi ?? .infinity, max(lo ?? -.infinity, v)) }

/// Drag sensitivity: about the step per pixel, finer for small ranges.
func scrubStep(_ step: Double, _ lo: Double?, _ hi: Double?) -> Double {
    if let lo, let hi, hi > lo { return min(step, max((hi - lo) / 300, 0.001)) }
    return step
}

/// Keyframe controls, ƒx toggle and the options menu.
private struct RowTrailing: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    @Binding var exprOpen: Bool
    var extra: AnyView? = nil

    var body: some View {
        // Fixed columns from the right: … menu, ƒx, ◆ — empty slots keep them lined up across rows.
        HStack(spacing: 0) {
            if let extra { extra }
            if slot.keyable {
                KeyControls(doc: doc, slot: slot, showReset: false)
            } else {
                Color.clear.frame(width: 18, height: 22)
            }
            if slot.exprAllowed { exprButton } else { Color.clear.frame(width: 20, height: 22) }
            RowMenu(doc: doc, slot: slot)
        }
        .fixedSize()
    }

    private var exprButton: some View {
        let on = slot.expr != nil
        return Button {
            if on {
                doc.setExpr(slot, nil)
            } else {
                doc.setExpr(slot, (doc.evaluated(slot) ?? slot.shown ?? 0).compactString)
                exprOpen = true
            }
        } label: {
            Text("ƒx").font(.system(size: 10.5, weight: .semibold, design: .serif)).italic()
                .foregroundStyle(on ? UI.onAccent : UI.faint)
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? UI.accent : .clear))
                .frame(width: 20, height: 22).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        .help(on ? "Expression on — click to turn back into a plain value" : "Drive this with an expression (t, T, i…)")
    }
}

/// "…" menu: easing into the key here, remove animation, reset.
private struct RowMenu: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot

    var body: some View {
        Menu {
            keyEasingMenu(doc, slot)
            if slot.isTop && slot.rootAnimated {
                Button("Remove animation (keep current value)") { doc.clearAnimation(in: slot.host, slot.root) }
            }
            if slot.isSet {
                Button(slot.field.defaultValue.map { "Reset to default (\($0.compactString))" } ?? "Remove") {
                    doc.write(slot, nil)
                }
            } else if let d = slot.field.defaultValue {
                Button("Set to default (\(d.compactString))") { doc.write(slot, d) }
            }
            Divider()
            Button("Copy value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    (slot.expr.map { "{\"expr\":\($0.debugDescription)}" }) ?? slot.shown?.compactString ?? "",
                    forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(UI.dim).frame(width: 18, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).cursor(.pointingHand)
        .help(slot.field.doc)
    }
}

/// A `numberOrObject` field holding the number shorthand (e.g. bloom 0.5): edited as its first sub-field,
/// with a button to expand into the full object.
private struct ShorthandRow: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let schema: ObjectSchema

    var body: some View {
        let first = schema.fields.first
        let f = Field(
            slot.field.name, first?.kind ?? .number(), slot.field.doc, label: slot.field.label,
            default: slot.field.defaultValue, animatable: slot.field.animatable)
        let s = doc.slot(slot.host, slot.root, path: slot.path, field: f)
        ScalarRow(doc: doc, slot: s, extra: AnyView(expand(first)))
    }

    private func expand(_ first: Field?) -> some View {
        Button {
            guard let first else { return }
            var o: [String: JSONValue] = [:]
            o[first.name] = slot.shown ?? first.defaultValue ?? 0
            doc.write(slot, .object(o))
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(UI.dim)
                .frame(width: 18, height: 22).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        .help("More options: " + schema.fields.map(\.label).joined(separator: ", "))
    }
}
