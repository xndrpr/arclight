import ArclightCore
import SwiftUI

/// ‹ ◆ › keyframe navigation (After Effects / Resolve style) plus "remove animation" for an animated prop.
struct KeyControls: View {
    let animated: Bool
    let keyHere: Bool
    var disabled = false
    let prev: () -> Void
    let toggle: () -> Void
    let next: () -> Void
    let reset: () -> Void
    /// Rows keep "remove animation" in their … menu; object headers show it here.
    var showReset = true

    var body: some View {
        HStack(spacing: 0) {
            if animated { small("chevron.left", "Previous keyframe", prev) }
            Button(action: toggle) {
                Image(systemName: keyHere ? "diamond.fill" : "diamond")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(keyHere ? UI.accent : (animated ? UI.label2 : UI.faint))
                    .frame(width: 18, height: 22).hitArea()
            }
            .buttonStyle(.plain).disabled(disabled)
            .help(
                keyHere
                    ? "Remove keyframe here"
                    : (animated ? "Add keyframe at playhead" : "Animate: add first keyframe at playhead")
            )
            .cursor(.pointingHand)
            if animated {
                small("chevron.right", "Next keyframe", next)
                if showReset { small("arrow.counterclockwise", "Remove animation, keep the current value", reset) }
            }
        }
        .fixedSize()
    }

    private func small(_ s: String, _ help: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(UI.label2)
                .frame(width: 16, height: 22).hitArea()
        }
        .buttonStyle(.plain).help(help).cursor(.pointingHand)
    }
}

extension KeyControls {
    /// Keyframe controls for a slot's root prop.
    init(doc: EditorDocument, slot: Slot, showReset: Bool = true) {
        self.init(
            animated: slot.rootAnimated, keyHere: slot.keyHere,
            prev: { doc.jumpKey(in: slot.host, slot.root, forward: false) },
            toggle: { doc.toggleKey(slot.host, slot.root) },
            next: { doc.jumpKey(in: slot.host, slot.root, forward: true) },
            reset: { doc.clearAnimation(in: slot.host, slot.root) }, showReset: showReset)
    }
}

/// "Easing into this keyframe" submenu, for a top-level slot with a key at the playhead.
@ViewBuilder func keyEasingMenu(_ doc: EditorDocument, _ slot: Slot) -> some View {
    if slot.isTop, let k = doc.keyHere(slot.host, slot.root) {
        Menu("Easing into this keyframe") {
            ForEach(Easing.names, id: \.self) { e in
                Button(e + (k.ease?.json.string == e ? "  ✓" : "")) { doc.setEase(slot.host, slot.root, Easing(e)) }
            }
        }
    }
}
