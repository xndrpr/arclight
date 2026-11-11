import AppKit
import SwiftUI

/// Dropdown styled like a field. Uses a native pop-up menu (SwiftUI's `Menu` drops the field styling when stretched).
struct ChoiceField: View {
    let value: String
    let options: [String]
    let commit: (String) -> Void
    var body: some View {
        FieldButton(action: { PopUpMenu.show(options, selected: value, pick: commit) }) {
            Text(value).font(UI.mono).foregroundStyle(UI.text).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// Shows a native menu of plain choices at the mouse, with the current one checked.
private enum PopUpMenu {
    final class Target: NSObject {
        let pick: (String) -> Void
        init(_ pick: @escaping (String) -> Void) { self.pick = pick }
        @objc func chosen(_ item: NSMenuItem) { pick(item.title) }
    }

    static func show(_ options: [String], selected: String?, pick: @escaping (String) -> Void) {
        let menu = NSMenu()
        let target = Target(pick)
        for o in options {
            let item = NSMenuItem(title: o, action: #selector(Target.chosen(_:)), keyEquivalent: "")
            item.target = target
            item.state = o == selected ? .on : .off
            menu.addItem(item)
        }
        let current = menu.items.first { $0.state == .on }
        withExtendedLifetime(target) { _ = menu.popUp(positioning: current, at: NSEvent.mouseLocation, in: nil) }
    }
}

/// One-line preview of JSON / an expression; click to edit in a code popover.
struct CodeField: View {
    let title: String
    let text: String
    let badge: String
    /// Returns an error message to keep the editor open, or nil on success.
    let apply: (String) -> String?
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 6) {
                Text(badge).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(UI.dim)
                Text(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))
                    .font(UI.mono).foregroundStyle(UI.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .fieldChrome()
        }
        .buttonStyle(.plain).cursor(.pointingHand).help("Click to edit as JSON")
        .popover(isPresented: $open, arrowEdge: .leading) {
            JSONPopover(title: title, text: text) { str in
                let e = apply(str)
                if e == nil { open = false }
                return e
            } cancel: {
                open = false
            }
        }
    }
}

/// Segmented control for a few options (Vercel style: hairline box, selected segment filled).
struct SegmentedChoice: View {
    let value: String?
    let options: [String]
    var dimmed = false
    let commit: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                if i > 0 { Rectangle().fill(UI.fieldBorder).frame(width: 1) }
                segment(o)
            }
        }
        .frame(height: UI.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder, lineWidth: 1))
    }

    private func segment(_ o: String) -> some View {
        let on = o == value
        return Button {
            commit(o)
        } label: {
            Text(o).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(on ? (dimmed ? UI.label2 : UI.onAccent) : UI.label2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(on ? (dimmed ? UI.selected : UI.accent) : Color.clear)
                .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}

/// Small on/off switch.
struct SwitchField: View {
    let value: Bool
    let commit: (Bool) -> Void
    var body: some View {
        Toggle("", isOn: Binding(get: { value }, set: { commit($0) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
    }
}

extension View {
    /// Greys out a widget that shows a default (the field isn't set yet; editing it adds it).
    func defaulted(_ on: Bool) -> some View { opacity(on ? 0.5 : 1) }
}
