import AppKit
import ArclightCore
import SwiftUI

struct NameRow: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var ui: LayerUIState
    let row: TLRow
    let childCount: Int
    let collapsed: Bool
    let order: [String]
    let thumbTime: Double
    let detailed: Bool
    /// Drop target for a drag at a y in the list (`NamesColumn.space`).
    var dropAt: (CGFloat) -> LayerTree.Drop? = { _ in nil }

    @State private var hover = false
    @State private var press = PressTracker()
    /// A plain press on an already selected row selects on release (so a multi-selection can be dragged).
    @State private var deferred = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var id: String { row.node.id }
    private var pinned: Bool { LayerTree.isPinned(id) }

    var body: some View {
        if let p = row.prop { propRow(p) } else { layerRow }
    }

    // MARK: Keyframe sub-row

    private func propRow(_ p: String) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(row.depth) * 12 + 18)
            Image(systemName: "diamond").font(.system(size: 7)).foregroundStyle(UI.faint)
            Text(Schema.field(row.node.type, p)?.label ?? p).font(UI.small).foregroundStyle(UI.label2).lineLimit(1)
            Spacer()
            if !pinned {
                IconButton(symbol: "chevron.left", help: "Previous keyframe") {
                    doc.jumpKey(forward: false, node: id, prop: p)
                }
                IconButton(symbol: "chevron.right", help: "Next keyframe") {
                    doc.jumpKey(forward: true, node: id, prop: p)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TL.rowH)
        .background(hover ? UI.hover.opacity(0.5) : .clear)
        .hitArea()
        .onHover { hover = $0 }
        .help("Animated property — the diamonds on the right are its keyframes")
    }

    // MARK: Layer row

    private var layerRow: some View {
        let n = row.node
        let selected = doc.selectedIds.contains(id)
        let primary = doc.selection == id
        let hidden = n.props["visible"] == .value(false)
        let locked = doc.isLockedDirect(id)
        let lockedByParent = !locked && !pinned && doc.isLocked(id)
        let soloed = doc.soloIds.contains(id)
        let soloDimmed = !pinned && !doc.isSoloVisible(id)
        let flashing = doc.flashIds.contains(id)
        let isGroup = n.type == "group"
        return HStack(spacing: 0) {
            Rectangle().fill(LayerLabel.color(n) ?? .clear).frame(width: 3)
            indentGuides
            disclosure(isGroup: isGroup)
            leading(n)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    nameView(n, hidden: hidden, primary: primary)
                    if is3D(n) { badge("3D") }
                }
                if detailed {
                    Text(summary(n)).font(.system(size: 10.5)).foregroundStyle(selected ? UI.dim : UI.faint).lineLimit(
                        1)
                }
            }
            .padding(.leading, 7)
            Spacer(minLength: 4)
            if !pinned {
                // Only the toggles that are on take layout space; hover shows all three in an overlay instead, so
                // the name never moves or re-truncates as the pointer comes and goes.
                toggles(all: false, soloed: soloed, locked: locked, lockedByParent: lockedByParent, hidden: hidden)
                    .opacity(hover ? 0 : 1).allowsHitTesting(!hover)
            }
        }
        .padding(.trailing, 6)
        .frame(height: TL.rowH)
        .overlay(alignment: .trailing) {
            if hover && !pinned {
                toggles(all: true, soloed: soloed, locked: locked, lockedByParent: lockedByParent, hidden: hidden)
                    .padding(.leading, 4).padding(.trailing, 6).frame(maxHeight: .infinity)
                    .background(  // opaque: covers the end of a long name
                        rowBackground(selected: selected, primary: primary, flashing: flashing).background(UI.panel))
            }
        }
        .opacity(soloDimmed ? 0.45 : (ui.dragging.contains(id) && ui.drop != nil ? 0.5 : 1))
        .background(rowBackground(selected: selected, primary: primary, flashing: flashing))
        .overlay(alignment: .leading) {
            if primary { Rectangle().fill(UI.accent).frame(width: 2).padding(.leading, 3) }
        }
        .overlay { dropIndicator }
        .overlay {
            RoundedRectangle(cornerRadius: 2).stroke(UI.ai.opacity(flashing ? 0.9 : 0), lineWidth: 1)
                .shadow(color: UI.ai.opacity(flashing ? 0.6 : 0), radius: 4).padding(1).allowsHitTesting(false)
        }
        .animation(Motion.animation(.easeOut(duration: flashing ? 0.15 : 0.9)), value: flashing)
        .hitArea()
        .onHover { hover = $0 }
        .gesture(rowGesture, including: renaming ? .subviews : .all)
        .help(
            pinned
                ? (id == LayerTree.cameraId
                    ? "Scene camera — select to edit it in the inspector"
                    : "Scene look: grade, bloom, fog — select to edit")
                : (n.name != nil ? "\(n.name!) — id “\(id)”" : "id “\(id)”") + (locked ? " · locked" : "")
                    + " · drag to reorder, double-click to rename"
        )
        .contextMenu { if !pinned { menu(n, hidden: hidden, locked: locked, soloed: soloed, isGroup: isGroup) } }
    }

    /// Press: select (or wait for release on an already selected row). Drag: reorder / re-parent. Release
    /// without a drag: click (double-click renames). Robust to tap-to-click jitter (`ClickSlop`).
    private var rowGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(NamesColumn.space))
            .onChanged { g in
                if !press.isPressed {
                    press.begin()
                    endEditing()
                    let mods = NSEvent.modifierFlags
                    deferred = mods.isDisjoint(with: [.command, .shift]) && doc.selectedIds.contains(id) && !pinned
                    if !deferred { doc.clickLayer(id, modifiers: mods, order: order) }
                    return
                }
                guard !pinned, press.update(g.translation) else { return }
                if ui.dragging.isEmpty { ui.dragging = doc.targets(id) }
                let z = dropAt(g.location.y)
                if ui.drop != z { ui.drop = z }
            }
            .onEnded { _ in
                let click = press.end()
                if click {
                    if deferred { doc.clickLayer(id, modifiers: [], order: order) }
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2, !pinned { beginRename() }
                } else if !ui.dragging.isEmpty, let z = ui.drop {
                    let ids = ui.dragging
                    withMotion(UI.snappy) { doc.moveLayers(ids, z) }
                }
                deferred = false
                ui.drop = nil
                ui.dragging = []
            }
    }

    private var indentGuides: some View {
        HStack(spacing: 0) {
            ForEach(0..<row.depth, id: \.self) { _ in
                Rectangle().fill(UI.border).frame(width: 1).padding(.leading, 11).padding(.trailing, 0).frame(
                    width: 12, alignment: .leading)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private func disclosure(isGroup: Bool) -> some View {
        if isGroup && childCount > 0 {
            Button {
                withMotion(UI.snappy) { ui.toggleCollapsed(id, scene: doc.scene.id) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(UI.dim).frame(width: 14, height: TL.rowH).hitArea()
            }
            .buttonStyle(.plain).help(
                collapsed ? "Expand (\(childCount) layer\(childCount == 1 ? "" : "s"))" : "Collapse"
            ).cursor(.pointingHand)
        } else {
            Spacer().frame(width: 14)
        }
    }

    /// Type icon (compact) or thumbnail with a small type badge (detailed).
    @ViewBuilder private func leading(_ n: Node) -> some View {
        let icon = Image(systemName: Self.icon(n)).font(.system(size: 10.5)).foregroundStyle(
            doc.selectedIds.contains(id) ? UI.text : UI.dim)
        if detailed {
            ZStack(alignment: .bottomLeading) {
                if pinned {
                    RoundedRectangle(cornerRadius: 3).fill(UI.raised)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.border, lineWidth: 1))
                        .overlay(Image(systemName: Self.icon(n)).font(.system(size: 13)).foregroundStyle(UI.label2))
                        .frame(width: LayerThumbs.size.width, height: LayerThumbs.size.height)
                } else {
                    LayerThumbnail(doc: doc, id: id, time: thumbTime)
                    Image(systemName: Self.icon(n)).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(UI.text)
                        .frame(width: 13, height: 11)
                        .background(
                            UnevenRoundedRectangle(cornerRadii: .init(bottomLeading: 3, topTrailing: 3)).fill(
                                UI.panel.opacity(0.85)))
                }
            }
        } else {
            icon.frame(width: 16)
        }
    }

    @ViewBuilder private func nameView(_ n: Node, hidden: Bool, primary: Bool) -> some View {
        if renaming {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain).font(UI.font).foregroundStyle(UI.text)
                .padding(.horizontal, 3).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.fieldBorder, lineWidth: 1))
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = false }
                .onChange(of: nameFocused) { _, f in if !f { commitRename() } }
        } else {
            Text(n.name ?? id).font(primary ? UI.font.weight(.medium) : UI.font)
                .foregroundStyle(hidden ? UI.faint : UI.text).strikethrough(hidden, color: UI.faint).lineLimit(1)
        }
    }

    func beginRename() {
        draft = row.node.name ?? id
        renaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        doc.rename(id, draft)
        DispatchQueue.main.async { endEditing() }
    }

    private func summary(_ n: Node) -> String {
        switch id {
        case LayerTree.cameraId: return LayerTree.cameraSummary(doc.scene)
        case LayerTree.lookId: return LayerTree.lookSummary(doc.scene)
        default: return Schema.summary(n, childCount: childCount)
        }
    }

    private func is3D(_ n: Node) -> Bool {
        !pinned && (n.props["3d"] == .value(true) || Schema.node(n.type)?.is3D == true)
    }

    private func badge(_ s: String) -> some View {
        Text(s).font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
            .padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.border))
    }

    private func toggle(
        _ symbol: String, active: Bool, dim: Bool = false, help: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5))
                .foregroundStyle(active ? UI.text : (dim ? UI.faint : UI.dim))
                .frame(width: 20, height: 22).hitArea()
        }
        .buttonStyle(.plain).help(help).cursor(.pointingHand)
    }

    /// Solo, lock and eye: every one with `all` (hover), else only those that are on.
    private func toggles(all: Bool, soloed: Bool, locked: Bool, lockedByParent: Bool, hidden: Bool) -> some View {
        HStack(spacing: 0) {
            if all || soloed {
                toggle(
                    soloed ? "s.circle.fill" : "s.circle", active: soloed,
                    help: soloed ? "Unsolo" : "Solo — show only this layer in the viewer"
                ) {
                    doc.toggleSolo(doc.targets(id))
                }
            }
            if all || locked || lockedByParent {
                toggle(
                    locked || lockedByParent ? "lock.fill" : "lock.open", active: locked, dim: lockedByParent,
                    help: lockedByParent
                        ? "Locked by a parent group"
                        : locked ? "Unlock" : "Lock — can't be picked or moved on the canvas or retimed"
                ) {
                    doc.setLocked(doc.targets(id), !locked)
                }
            }
            if all || hidden {
                toggle(hidden ? "eye.slash" : "eye", active: hidden, help: hidden ? "Show (D)" : "Hide (D)") {
                    doc.setHidden(doc.targets(id), !hidden)
                }
            }
        }
    }

    private func rowBackground(selected: Bool, primary: Bool, flashing: Bool) -> Color {
        if flashing { return UI.ai.opacity(0.14) }
        if primary { return UI.selected }
        if selected { return UI.selected.opacity(0.65) }
        if hover { return UI.hover }
        return pinned ? UI.raised : .clear  // scene rows sit on a slightly raised band
    }

    @ViewBuilder private var dropIndicator: some View {
        switch ui.drop {
        case .above(let t)? where t == id:
            VStack {
                DropLine(); Spacer()
            }.allowsHitTesting(false)
        case .below(let t)? where t == id:
            VStack {
                Spacer(); DropLine()
            }.allowsHitTesting(false)
        case .into(let t)? where t == id:
            RoundedRectangle(cornerRadius: 3).fill(UI.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.accent, lineWidth: 1.5)).padding(1)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    /// Shape-specific icon, else the schema's.
    private static func icon(_ n: Node) -> String {
        switch n.type {
        case "camera": return "video"
        case "look": return "camera.filters"
        case "shape":
            switch n.props["shape"].flatMap({
                if case .value(let v) = $0 { return v.string }; return nil
            }) ?? "rect" {
            case "ellipse": return "circle"
            case "line": return "line.diagonal"
            default: return "rectangle"
            }
        default: return Schema.node(n.type)?.icon ?? symbol(for: n.type)
        }
    }
}

/// Insertion line for a layer drag: accent bar with a dot at its start.
private struct DropLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().stroke(UI.accent, lineWidth: 1.5).frame(width: 6, height: 6)
            Rectangle().fill(UI.accent).frame(height: 2)
        }
        .frame(height: 6).padding(.leading, 4)
    }
}
