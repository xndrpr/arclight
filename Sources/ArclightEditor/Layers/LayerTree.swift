import ArclightCore
import Foundation

/// Pure layer-list logic over a `Scene`: visible rows (hierarchy, collapse, filter, pinned scene rows),
/// selection ranges, and the scene ops for reorder / re-parent / group / ungroup. Everything that changes
/// the scene returns `[JSONValue]` ops for `EditorDocument.apply` (same path the AI uses, undoable).
enum LayerTree {
    /// Pinned scene rows. Not real nodes: selecting them selects the scene's camera / look (post + fog).
    static let cameraId = "@camera"
    static let lookId = "@look"
    static func isPinned(_ id: String) -> Bool { id.hasPrefix("@") }

    // MARK: Hierarchy

    /// Parent id if it names an existing node (dangling parents count as root).
    static func parent(_ n: Node, in s: Scene) -> String? {
        guard let p = n.parent, p != n.id, s.node(p) != nil else { return nil }
        return p
    }

    /// Children per parent id ("" = root), in array (draw) order.
    static func children(_ s: Scene) -> [String: [Node]] {
        let ids = Set(s.nodes.map(\.id))
        var out: [String: [Node]] = [:]
        for n in s.nodes {
            out[n.parent.flatMap { ids.contains($0) && $0 != n.id ? $0 : nil } ?? "", default: []].append(n)
        }
        return out
    }

    /// Ancestor ids, nearest first (cycle-safe).
    static func ancestors(_ s: Scene, _ id: String) -> [String] {
        var out: [String] = [], seen: Set<String> = [id]
        var cur = s.node(id).flatMap { parent($0, in: s) }
        while let c = cur, seen.insert(c).inserted {
            out.append(c)
            cur = s.node(c).flatMap { parent($0, in: s) }
        }
        return out
    }

    /// The node and all its descendants, in array order.
    static func subtree(_ s: Scene, _ id: String) -> [String] {
        var set: Set<String> = [id], frontier = [id]
        while let c = frontier.popLast() {
            for n in s.nodes where n.parent == c && set.insert(n.id).inserted { frontier.append(n.id) }
        }
        return s.nodes.map(\.id).filter { set.contains($0) }
    }

    /// Ids whose ancestors are not also in `ids`, in array order.
    static func topLevel(_ s: Scene, _ ids: Set<String>) -> [String] {
        s.nodes.map(\.id).filter { ids.contains($0) && !ancestors(s, $0).contains(where: ids.contains) }
    }

    // MARK: Rows

    /// Search: id, name, type (and shape kind), text content.
    static func matches(_ n: Node, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        var hay = [n.id, n.name ?? "", n.type, Schema.node(n.type)?.label ?? ""]
        if case .value(let v)? = n.props["shape"], let k = v.string { hay.append(k) }
        if case .value(let v)? = n.props["text"], let t = v.string { hay.append(t) }
        if case .value(let v)? = n.props["src"], let t = v.string { hay.append(t) }
        return hay.contains { $0.lowercased().contains(q) }
    }

    /// Timeline/list rows: pinned scene rows, then top-most layer first with children under parents
    /// (skipping collapsed groups), then the selected row's animated props as sub-rows.
    /// With a filter, only matches and their ancestors are shown (and collapse is ignored).
    static func rows(
        _ s: Scene, selection: String?, collapsed: Set<String> = [], filter: String = "", pinned: Bool = true
    ) -> [TLRow] {
        let kids = children(s)
        let q = filter.trimmingCharacters(in: .whitespaces)
        var keep: Set<String>?
        if !q.isEmpty {
            var k = Set<String>()
            for n in s.nodes where matches(n, q) { k.insert(n.id); k.formUnion(ancestors(s, n.id)) }
            keep = k
        }
        var out: [TLRow] = []
        func addProps(_ n: Node, _ depth: Int) {
            guard n.id == selection, n.id != cameraId else { return }  // the camera row already shows its keys
            for k in n.props.keys.sorted() where n.props[k]!.keyCount > 0 {
                out.append(TLRow(node: n, prop: k, depth: depth + 1))
            }
        }
        if pinned {
            for n in pseudoNodes(s) where q.isEmpty || matches(n, q) {
                out.append(TLRow(node: n, prop: nil, depth: 0)); addProps(n, 0)
            }
        }
        var visited = Set<String>()
        func walk(_ parent: String, _ depth: Int) {
            for n in (kids[parent] ?? []).reversed() where visited.insert(n.id).inserted {
                if let keep, !keep.contains(n.id) { continue }
                out.append(TLRow(node: n, prop: nil, depth: depth))
                addProps(n, depth)
                if keep != nil || !collapsed.contains(n.id) { walk(n.id, depth + 1) }
            }
        }
        walk("", 0)
        return out
    }

    /// Ids of real layer rows in visual (top → bottom) order.
    static func visualOrder(_ rows: [TLRow]) -> [String] {
        rows.filter { $0.prop == nil && !isPinned($0.node.id) }.map(\.node.id)
    }

    /// ⇧-click: everything between the anchor and the clicked row (inclusive), in visual order.
    static func rangeSelect(order: [String], anchor: String?, to id: String) -> [String] {
        guard let j = order.firstIndex(of: id) else { return [id] }
        guard let a = anchor, let i = order.firstIndex(of: a) else { return [id] }
        return Array(order[min(i, j)...max(i, j)])
    }

    // MARK: Ops

    /// Where a dragged row lands: above / below a row (as its sibling), or into a group (on top of its children).
    enum Drop: Equatable { case above(String), below(String), into(String) }

    private static func idx(_ s: Scene, _ id: String) -> Int { s.nodes.firstIndex { $0.id == id } ?? -1 }

    /// Where dragged rows would land with the pointer at `y` (list coordinates, rows of height `rowH`):
    /// top / bottom half of a row = above / below it; the middle of a group = into it; below the last row =
    /// below the bottom-most layer. Nil over pinned rows or over the dragged rows themselves (and their children).
    static func dropZone(
        _ s: Scene, rows: [TLRow], y: CGFloat, rowH: CGFloat, collapsed: Set<String>, dragging: [String]
    ) -> Drop? {
        let layerRows = rows.filter { $0.prop == nil && !isPinned($0.node.id) }
        guard rowH > 0, let last = layerRows.last, !dragging.isEmpty else { return nil }
        let i = Int(floor(y / rowH))
        if i >= rows.count { return blocked(s, last.node.id, dragging) ? nil : .below(last.node.id) }
        guard i >= 0 else { return nil }
        let r = rows[i]
        if isPinned(r.node.id) {
            return blocked(s, layerRows[0].node.id, dragging) ? nil : .above(layerRows[0].node.id)
        }
        let id = r.node.id
        if blocked(s, id, dragging) { return nil }
        if r.prop != nil { return .below(id) }  // keyframe sub-rows sit under their layer
        let f = (y - CGFloat(i) * rowH) / rowH
        if r.node.type == "group" {
            let expandedWithKids = !collapsed.contains(id) && s.nodes.contains { $0.parent == id }
            if f < 0.28 { return .above(id) }
            if f > 0.72 { return expandedWithKids ? .into(id) : .below(id) }
            return .into(id)
        }
        return f < 0.5 ? .above(id) : .below(id)
    }

    private static func blocked(_ s: Scene, _ target: String, _ dragging: [String]) -> Bool {
        dragging.contains(target) || ancestors(s, target).contains(where: dragging.contains)
    }

    /// Reorders and/or re-parents layers (each with its subtree, relative draw order kept).
    static func moveOps(_ s: Scene, ids: [String], drop: Drop) -> [JSONValue] {
        let roots = topLevel(s, Set(ids))
        guard !roots.isEmpty else { return [] }
        let target: String
        switch drop {
        case .above(let t), .below(let t), .into(let t): target = t
        }
        guard let tn = s.node(target) else { return [] }
        let block = roots.flatMap { subtree(s, $0) }
        guard !block.contains(target) else { return [] }  // can't drop onto itself / its own children
        let newParent: String?
        let first: JSONValue
        let head = block[0]
        switch drop {
        case .above(let t):
            newParent = parent(tn, in: s)
            let anchor = subtree(s, t).max { idx(s, $0) < idx(s, $1) } ?? t
            first = ["op": "move", "id": .string(head), "after": .string(anchor)]
        case .below(let t):
            newParent = parent(tn, in: s)
            let anchor = subtree(s, t).min { idx(s, $0) < idx(s, $1) } ?? t
            first = ["op": "move", "id": .string(head), "before": .string(anchor)]
        case .into(let g):
            newParent = g
            let anchor = subtree(s, g).max { idx(s, $0) < idx(s, $1) } ?? g
            first = ["op": "move", "id": .string(head), "after": .string(anchor)]
        }
        var ops: [JSONValue] = []
        let reparent = roots.filter { s.node($0).flatMap { parent($0, in: s) } != newParent }
        if !reparent.isEmpty {
            ops.append([
                "op": "set", "ids": .array(reparent.map { .string($0) }),
                "parent": newParent.map { .string($0) } ?? .null,
            ])
        }
        ops.append(first)
        for (prev, id) in zip(block, block.dropFirst()) {
            ops.append(["op": "move", "id": .string(id), "after": .string(prev)])
        }
        return ops
    }

    /// Bring forward / send backward: swaps a layer (with its subtree) with its next / previous sibling.
    static func reorderOps(_ s: Scene, id: String, forward: Bool) -> [JSONValue] {
        guard let n = s.node(id) else { return [] }
        let sibs = children(s)[parent(n, in: s) ?? ""] ?? []
        guard let i = sibs.firstIndex(where: { $0.id == id }) else { return [] }
        let j = forward ? i + 1 : i - 1
        guard sibs.indices.contains(j) else { return [] }
        return moveOps(s, ids: [id], drop: forward ? .above(sibs[j].id) : .below(sibs[j].id))
    }

    /// ⌘G: a new group at the selection's top position (in the shared parent, else at root) holding the layers.
    static func groupOps(_ s: Scene, ids: Set<String>, groupId: String) -> [JSONValue] {
        let roots = topLevel(s, ids.filter { s.node($0) != nil })
        guard let top = roots.max(by: { idx(s, $0) < idx(s, $1) }) else { return [] }
        let parents = Set(roots.map { s.node($0).flatMap { parent($0, in: s) } ?? "" })
        let p = parents.count == 1 ? parents.first! : ""
        var node: [String: JSONValue] = ["id": .string(groupId), "type": "group"]
        if !p.isEmpty { node["parent"] = .string(p) }
        return [
            ["op": "add", "node": .object(node), "after": .string(top)],
            ["op": "set", "ids": .array(roots.map { .string($0) }), "parent": .string(groupId)],
        ]
    }

    /// ⇧⌘G: moves each group's children to the group's parent and removes the group. A plain translation
    /// on the group (x / y / z, no rotation, scale or anchor) is added to the children so nothing jumps.
    static func ungroupOps(_ s: Scene, groups: [String]) -> [JSONValue] {
        var ops: [JSONValue] = []
        for g in groups {
            guard let gn = s.node(g), gn.type == "group" else { continue }
            let kids = s.nodes.filter { $0.parent == g }
            let p = parent(gn, in: s)
            let blockers: Set<String> = ["rotation", "rotationX", "rotationY", "scale", "anchor"]
            let bakeable = !gn.props.keys.contains(where: blockers.contains)
            var offset: [String: Double] = [:]
            if bakeable {
                for k in ["x", "y", "z"] {
                    if case .value(let v)? = gn.props[k], let d = v.double, d != 0 { offset[k] = d }
                }
            }
            for c in kids {
                var op: [String: JSONValue] = [
                    "op": "set", "id": .string(c.id), "parent": p.map { .string($0) } ?? .null,
                ]
                for (k, d) in offset {
                    switch c.props[k] {
                    case nil: op[k] = .number(d)
                    case .value(let v)?: if let x = v.double { op[k] = .number(x + d) }
                    case .keys(let ks)?:
                        op[k] =
                            Prop.keys(
                                ks.map { kf in
                                    var kf = kf; if let x = kf.v.double { kf.v = .number(x + d) }; return kf
                                }
                            ).json
                    case .expr?: break
                    }
                }
                ops.append(.object(op))
            }
            ops.append(["op": "remove", "id": .string(g)])
        }
        return ops
    }

    // MARK: Pinned scene rows

    /// Pseudo nodes for the timeline: their props are the scene's camera / post / fog, so keyframes show up.
    static func pseudoNodes(_ s: Scene) -> [Node] {
        var cam = Node(id: cameraId, type: "camera")
        cam.name = "Camera"
        if let c = s.camera { cam.props["camera"] = c }
        var look = Node(id: lookId, type: "look")
        look.name = "Look"
        if let p = s.post { look.props["post"] = p }
        if let f = s.fog { look.props["fog"] = f }
        return [cam, look]
    }

    private static func first(_ p: Prop?) -> JSONValue? {
        switch p {
        case .value(let v)?: return v
        case .keys(let ks)?: return ks.first?.v
        default: return nil
        }
    }

    /// "fov 36 · moving · dof"
    static func cameraSummary(_ s: Scene) -> String {
        guard let c = s.camera else { return "not set · 2D only" }
        if case .expr = c { return "expression" }
        let v = first(c)
        var parts: [String] = []
        if let f = v?["fov"]?.double { parts.append("fov \(fmt(f))") }
        parts.append(c.keyCount > 1 ? "moving" : "static")
        if v?["dof"]?.object != nil { parts.append("dof") }
        if v?["shake"] != nil { parts.append("shake") }
        return parts.joined(separator: " · ")
    }

    /// "B&W · bloom · grain · fog"
    static func lookSummary(_ s: Scene) -> String {
        var parts: [String] = []
        if let p = first(s.post) {
            if let sat = p["saturation"]?.double {
                if sat == 0 { parts.append("B&W") } else if sat != 1 { parts.append("sat \(fmt(sat))") }
            }
            if let c = p["contrast"]?.double, c != 1 { parts.append("contrast") }
            if let e = p["exposure"]?.double, e != 0 { parts.append("exposure") }
            for (k, label) in [
                ("bloom", "bloom"), ("vignette", "vignette"), ("grain", "grain"), ("motionBlur", "motion blur"),
                ("fade", "fade"),
            ] {
                if let x = p[k], x != .bool(false), x != .number(0), x != .null { parts.append(label) }
            }
        }
        if s.fog != nil { parts.append("fog") }
        if s.post?.isAnimated == true || s.fog?.isAnimated == true { parts.append("◆") }
        return parts.isEmpty ? "no grade" : parts.joined(separator: " · ")
    }
}
