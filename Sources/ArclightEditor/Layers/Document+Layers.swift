import AppKit
import ArclightCore
import SwiftUI

/// Colour labels (`_label` on a node): a stripe in the layer row and a tint on its timeline bar.
enum LayerLabel {
    static let names = ["red", "orange", "yellow", "green", "blue", "purple", "gray"]
    static func color(_ name: String) -> Color? {
        switch name {
        case "red": return Color(red: 0.93, green: 0.33, blue: 0.33)
        case "orange": return Color(red: 0.96, green: 0.58, blue: 0.24)
        case "yellow": return Color(red: 0.93, green: 0.82, blue: 0.3)
        case "green": return Color(red: 0.36, green: 0.8, blue: 0.46)
        case "blue": return Color(red: 0.36, green: 0.6, blue: 0.98)
        case "purple": return Color(red: 0.68, green: 0.48, blue: 0.96)
        case "gray": return Color(white: 0.55)
        default: return nil
        }
    }
    static func name(_ n: Node) -> String? {
        if case .value(let v)? = n.props["_label"] { return v.string }; return nil
    }
    static func color(_ n: Node) -> Color? { name(n).flatMap(color) }
}

/// Row density, persisted. `TL.rowH` reads it so names and tracks stay aligned.
enum LayerDensity: String {
    case compact, detailed
    static var current: LayerDensity {
        LayerDensity(rawValue: Pref.store.string(forKey: Pref.layerDensity) ?? "") ?? .detailed
    }
    var rowHeight: CGFloat { self == .compact ? 26 : 44 }
}

/// Per-document layer-list state that isn't scene data: collapsed groups (persisted per project + scene),
/// filter text, ⇧-click anchor and the current drop indicator.
final class LayerUIState: ObservableObject {
    weak var doc: EditorDocument?
    init(doc: EditorDocument) { self.doc = doc }

    /// Changing these re-lays out the timeline, which observes the document.
    var filter = "" { willSet { doc?.objectWillChange.send() } }
    var anchor: String?
    var dragging: [String] = []
    /// Time used for thumbnails (frozen while playing).
    var thumbTime: Double = 0
    @Published var drop: LayerTree.Drop?

    private func key(_ scene: String) -> String { Pref.layersCollapsed(projectPath: doc?.url.path ?? "", scene: scene) }

    func collapsed(_ scene: String) -> Set<String> { Set(Pref.store.stringArray(forKey: key(scene)) ?? []) }

    func toggleCollapsed(_ id: String, scene: String) {
        var c = collapsed(scene)
        if c.contains(id) { c.remove(id) } else { c.insert(id) }
        doc?.objectWillChange.send()
        Pref.store.set(Array(c).sorted(), forKey: key(scene))
    }
}

private let layerUIStates = NSMapTable<EditorDocument, LayerUIState>.weakToStrongObjects()

extension EditorDocument {
    var layerUI: LayerUIState {
        if let s = layerUIStates.object(forKey: self) { return s }
        let s = LayerUIState(doc: self)
        layerUIStates.setObject(s, forKey: self)
        return s
    }

    /// Rows shown in the layer list and the timeline (pinned scene rows, hierarchy, collapse, filter).
    func layerRows() -> [TLRow] {
        LayerTree.rows(scene, selection: selection, collapsed: layerUI.collapsed(scene.id), filter: layerUI.filter)
    }

    // MARK: Lock / solo / visibility / label

    /// Locked (`_locked`, on the layer or an ancestor) layers can't be picked or dragged on the canvas or
    /// retimed in the timeline. Pinned scene rows (camera / look) are never retimable either.
    func isLocked(_ id: String) -> Bool {
        if LayerTree.isPinned(id) { return true }
        return ([id] + LayerTree.ancestors(scene, id)).contains { isLockedDirect($0) }
    }

    func isLockedDirect(_ id: String) -> Bool { scene.node(id)?.props["_locked"] == .value(true) }

    /// Ids a row action applies to: the whole selection when the row is part of it, else just the row.
    func targets(_ id: String) -> [String] {
        let sel = selectedIds.filter { scene.node($0) != nil }
        return sel.contains(id) ? LayerTree.topLevel(scene, sel) : [id]
    }

    func setLocked(_ ids: [String], _ on: Bool) {
        edit { s in
            for i in s.nodes.indices where ids.contains(s.nodes[i].id) {
                s.nodes[i].props["_locked"] = on ? .value(true) : nil
            }
        }
    }

    func setHidden(_ ids: [String], _ on: Bool) {
        edit { s in
            for i in s.nodes.indices where ids.contains(s.nodes[i].id) {
                s.nodes[i].props["visible"] = on ? .value(false) : nil
            }
        }
    }

    func setLabel(_ ids: [String], _ name: String?) {
        edit { s in
            for i in s.nodes.indices where ids.contains(s.nodes[i].id) {
                s.nodes[i].props["_label"] = name.map { .value(.string($0)) }
            }
        }
    }

    func toggleSolo(_ ids: [String]) {
        if ids.allSatisfy(soloIds.contains) { soloIds.subtract(ids) } else { soloIds.formUnion(ids) }
    }

    /// True when the layer draws under the current solo (it or an ancestor is solo'd).
    func isSoloVisible(_ id: String) -> Bool {
        soloIds.isEmpty || ([id] + LayerTree.ancestors(scene, id)).contains(where: soloIds.contains)
    }

    func rename(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let new: String? = n.isEmpty || n == id ? nil : n
        guard let node = scene.node(id), node.name != new else { return }
        apply([["op": "set", "id": .string(id), "name": new.map { .string($0) } ?? .null]])
    }

    func deleteLayers(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        apply([["op": "remove", "ids": .array(ids.map { .string($0) })]])
        if let s = selection, scene.node(s) == nil { selection = nil }
        multiSelection = multiSelection.filter { scene.node($0) != nil }
        soloIds = soloIds.filter { scene.node($0) != nil }
    }

    // MARK: Selection

    /// Click (replace), ⌘-click (toggle), ⇧-click (range in visual order).
    func clickLayer(_ id: String, modifiers: NSEvent.ModifierFlags, order: [String]) {
        let ui = layerUI
        if LayerTree.isPinned(id) || modifiers.isDisjoint(with: [.command, .shift]) {
            multiSelection = []
            selection = id
            ui.anchor = id
        } else if modifiers.contains(.shift) {
            let range = LayerTree.rangeSelect(
                order: order, anchor: ui.anchor ?? selection.flatMap { LayerTree.isPinned($0) ? nil : $0 }, to: id)
            multiSelection = Set(range).subtracting([id])
            selection = id
        } else {
            var all = selectedIds.filter { !LayerTree.isPinned($0) }
            if all.contains(id) { all.remove(id) } else { all.insert(id) }
            let primary =
                all.contains(id)
                ? id : (selection.flatMap { all.contains($0) ? $0 : nil } ?? order.first(where: all.contains))
            multiSelection = all.subtracting(primary.map { [$0] } ?? [])
            selection = primary
            ui.anchor = id
        }
    }

    // MARK: Structure

    func moveLayers(_ ids: [String], _ drop: LayerTree.Drop) {
        let ops = LayerTree.moveOps(scene, ids: ids, drop: drop)
        if !ops.isEmpty { apply(ops) }
    }

    func reorderLayer(_ id: String, forward: Bool) {
        let ops = LayerTree.reorderOps(scene, id: id, forward: forward)
        if !ops.isEmpty { apply(ops) }
    }

    /// ⌘G
    func groupSelection(_ ids: [String]? = nil) {
        let set = Set(ids ?? Array(selectedIds)).filter { scene.node($0) != nil }
        guard !set.isEmpty else { flash("Select layers to group"); return }
        let gid = SceneOps.uniqueId("group", in: scene)
        apply(LayerTree.groupOps(scene, ids: set, groupId: gid))
        guard scene.node(gid) != nil else { return }
        multiSelection = []
        selection = gid
    }

    /// ⇧⌘G
    func ungroupSelection(_ ids: [String]? = nil) {
        let groups = LayerTree.topLevel(scene, Set(ids ?? Array(selectedIds))).filter {
            scene.node($0)?.type == "group"
        }
        guard !groups.isEmpty else { flash("Select a group to ungroup"); return }
        let kids = scene.nodes.filter { $0.parent.map(groups.contains) ?? false }.map(\.id)
        apply(LayerTree.ungroupOps(scene, groups: groups))
        soloIds.subtract(groups)
        selection = kids.last
        multiSelection = Set(kids.dropLast())
    }
}

/// Menu actions for ⌘G / ⇧⌘G (items added in `buildMenu`).
extension EditorWindowController {
    @objc func groupLayers(_ sender: Any?) { doc.groupSelection() }
    @objc func ungroupLayers(_ sender: Any?) { doc.ungroupSelection() }
}
