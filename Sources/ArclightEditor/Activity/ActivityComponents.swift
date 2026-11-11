import ArclightCore
import SwiftUI

/// Wraps children onto multiple lines (layer chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var items: [Int] = []; var xs: [CGFloat] = []; var width: CGFloat = 0; var height: CGFloat = 0;
        var y: CGFloat = 0
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            var r = rows[rows.count - 1]
            let x = r.items.isEmpty ? 0 : r.width + spacing
            if !r.items.isEmpty && x + s.width > maxWidth {
                let y = r.y + r.height + spacing
                rows.append(Row(y: y)); r = rows[rows.count - 1]
                r.items = [i]; r.xs = [0]; r.width = s.width; r.height = s.height
            } else {
                r.items.append(i); r.xs.append(x); r.width = x + s.width; r.height = max(r.height, s.height)
            }
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// A layer id that selects the layer when clicked (switching scene first if needed).
struct LayerChip: View {
    @ObservedObject var doc: EditorDocument
    let id: String
    let scene: String?
    @State private var hover = false

    var body: some View {
        let exists = doc.layerExists(id, in: scene)
        let selected = exists && doc.selection == id && (scene == nil || scene == doc.scene.id)
        Button {
            doc.reveal(scene: scene, layer: id)
        } label: {
            Text(id).font(UI.monoSmall).lineLimit(1)
                .foregroundStyle(selected ? UI.onAccent : exists ? (hover ? UI.text : UI.label2) : UI.faint)
                .strikethrough(!exists, color: UI.faint)
                .padding(.horizontal, 6).frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(
                        selected ? UI.accent : hover && exists ? UI.hover : UI.raised)
                )
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? .clear : UI.border, lineWidth: 1))
                .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(
            exists
                ? "Select \(id)" + (scene != nil && scene != doc.scene.id ? " in \(scene!)" : "")
                : "\(id) no longer exists"
        )
        .cursor(exists ? .pointingHand : .arrow)
        .disabled(!exists)
    }
}

/// "5m" that keeps itself up to date.
struct RelativeTime: View {
    let date: Date?
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 10)) { ctx in
            Text(ActivityFeed.relative(date, now: ctx.date)).font(UI.monoSmall).foregroundStyle(UI.faint)
                .help(date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "")
        }
    }
}

/// Small outlined button that asks for a second click instead of a modal ("Revert" → "Confirm revert").
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    var symbol: String = "arrow.uturn.backward"
    var help: String = ""
    let action: () -> Void
    @State private var armed = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if armed {
                    armed = false; action()
                } else {
                    armed = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: armed ? "checkmark" : symbol).font(.system(size: 9, weight: .semibold))
                    Text(armed ? confirmTitle : title).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(armed ? UI.onAccent : (hover ? UI.text : UI.label2))
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(armed ? UI.accent : hover ? UI.hover : UI.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(armed ? .clear : UI.border, lineWidth: 1))
                .hitArea()
            }
            .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand).help(
                armed ? "Click again to confirm" : help)
            if armed {
                Button {
                    armed = false
                } label: {
                    Text("Cancel").font(.system(size: 11)).foregroundStyle(UI.dim).padding(.horizontal, 4).frame(
                        height: 22
                    ).hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand)
            }
        }
        .animation(Motion.animation(UI.fade), value: armed)
        // Disarms 4 s after this arming; confirming or cancelling cancels the timer, so re-arming starts a new one.
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { armed = false }
        }
    }
}

/// Small outlined text button (Compare, Copy…).
struct SmallButton: View {
    let title: String
    var symbol: String?
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(HoverButtonStyle(name: "small button \(title)")).help(help)
    }
}

/// Sparkle for an AI agent, terminal for the command line, person for the user.
/// `source` is a `ChangeSource` raw value.
struct SourceIcon: View {
    let source: String?
    var agent: String? = nil
    var body: some View {
        let kind = source.flatMap(ChangeSource.init(rawValue:))
        let ai = kind == .ai, cli = kind == .cli
        Image(systemName: ai ? "sparkle" : cli ? "terminal" : "person.fill").font(.system(size: 9))
            .foregroundStyle(ai ? UI.ai : UI.dim).frame(width: 12)
            .help(ai ? (agent ?? "AI agent") : cli ? "Command line" : "You")
    }
}
