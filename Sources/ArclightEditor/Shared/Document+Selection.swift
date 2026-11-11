import AppKit
import ArclightCore

extension EditorDocument {
    /// Real layers in the selection (pinned rows like "@camera" excluded), in draw order.
    var selectedLayerIds: [String] { scene.nodes.map(\.id).filter { selectedIds.contains($0) } }

    func deleteSelection() {
        let ids = selectedLayerIds
        guard !ids.isEmpty else { return }
        apply([["op": "remove", "ids": .array(ids.map { .string($0) })]])
        selection = nil
        multiSelection = []
        soloIds = soloIds.filter { scene.node($0) != nil }
    }

    func duplicateSelection() {
        let ids = selectedLayerIds
        guard !ids.isEmpty else { return }
        // Skip layers whose parent is also selected (duplicating the parent already copies them).
        let roots = ids.filter { id in !(scene.node(id)?.parent.map { ids.contains($0) } ?? false) }
        var ops: [JSONValue] = [], made: [String] = []
        var probe = scene
        for id in roots {
            let newId = SceneOps.uniqueId(id, in: probe)
            probe.nodes.append(Node(id: newId, type: "group"))
            ops.append(["op": "duplicate", "id": .string(id), "as": .string(newId), "after": .string(id)])
            made.append(newId)
        }
        apply(ops)
        selection = made.last
        multiSelection = Set(made.dropLast())
    }

    func addNode(_ type: String, props: [String: JSONValue], idBase: String? = nil) {
        let base = idBase ?? props["shape"]?.string ?? type
        let id = SceneOps.uniqueId(base, in: scene)
        var node: [String: JSONValue] = ["id": .string(id), "type": .string(type)]
        for (k, v) in props { node[k] = v }
        if scene.nodes.isEmpty == false, type != "repeater", type != "light", props["in"] == nil, time > 0.001 {
            node["in"] = .number((time * fps).rounded() / fps)
        }
        apply([["op": "add", "node": .object(node)]])
        selection = id
    }

    // MARK: Layer commands

    func setInOut(isIn: Bool) {
        guard let id = selection else { flash("Select a layer first"); return }
        let t = (time * fps).rounded() / fps
        apply([["op": "set", "id": .string(id), isIn ? "in" : "out": .number(t)]])
    }

    func clearInOut() {
        guard let id = selection else { return }
        apply([["op": "set", "id": .string(id), "in": .null, "out": .null]])
    }

    func toggleEnabled() {
        guard let id = selection, let n = scene.node(id) else { return }
        setRaw(id, "visible", n.props["visible"] == .value(false) ? nil : .value(false))
    }

    func moveSelection(_ dir: Int) {
        guard let id = selection, let i = scene.nodes.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(scene.nodes.count - 1, i + dir))
        guard j != i else { return }
        apply([["op": "move", "id": .string(id), dir > 0 ? "after" : "before": .string(scene.nodes[j].id)]])
    }

    private static let pasteType = NSPasteboard.PasteboardType("com.xndrpr.arclight.nodes")

    /// Copies the selected layer and its children as JSON (also readable as text, e.g. to paste to the AI).
    func copySelection() {
        let roots = selectedLayerIds
        guard let id = roots.last else { return }
        var ids = roots, frontier = roots
        while let c = frontier.popLast() {
            for n in scene.nodes where n.parent == c { ids.append(n.id); frontier.append(n.id) }
        }
        let nodes = scene.nodes.filter { ids.contains($0.id) }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(nodes), let str = String(data: data, encoding: .utf8) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: Self.pasteType)
        pb.setString(str, forType: .string)
        flash(roots.count == 1 ? "Copied \(id)" : "Copied \(roots.count) layers")
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func paste() {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: Self.pasteType) ?? pb.string(forType: .string),
            let nodes = try? JSONDecoder().decode([Node].self, from: Data(str.utf8)), !nodes.isEmpty
        else { return }
        var s = scene
        var rename: [String: String] = [:]
        for n in nodes {
            let nid = SceneOps.uniqueId(n.id, in: s); rename[n.id] = nid; s.nodes.append(Node(id: nid, type: "group"))
        }
        let renamed = nodes.map { n -> Node in
            var c = n; c.id = rename[n.id]!;
            c.parent = n.parent.flatMap { rename[$0] ?? (scene.node($0) != nil ? $0 : nil) }; return c
        }
        edit { $0.nodes.append(contentsOf: renamed) }
        selection = renamed.first?.id
    }
}
