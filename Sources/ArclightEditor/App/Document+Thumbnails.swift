import ArclightCore
import Foundation

/// The two things a project can hold. A project may have only one of them.
enum Workspace: String, CaseIterable, Identifiable {
    case motion, thumbnail
    var id: String { rawValue }
    var title: String { self == .motion ? "Motion" : "Thumbnails" }
    var symbol: String { self == .motion ? "film" : "photo.on.rectangle" }
}

/// What the document's working `scene` is a copy of.
enum EditTarget: Equatable {
    case scene(String)
    case artboard(thumbnail: String, artboard: String)
    /// Nothing to edit yet (an empty workspace); `scene` is a placeholder that is never saved.
    case none

    var thumbnailId: String? { if case .artboard(let p, _) = self { return p }; return nil }
    var artboardId: String? { if case .artboard(_, let a) = self { return a }; return nil }
}

extension EditorDocument {
    static let placeholderSceneId = "~none"

    /// A new page with one YouTube-sized artboard on the theme background.
    static func starterThumbnail(id: String, name: String? = nil) -> Thumbnail {
        var a = Artboard(id: "a", name: "A")
        a.background = .value("$bg")
        return Thumbnail(id: id, name: name ?? "Thumbnail", artboards: [a])
    }

    static func placeholderScene() -> Scene { Scene(id: placeholderSceneId, duration: 5) }

    /// The first thing to open in a workspace: its first scene, or the first artboard of its first thumbnail.
    static func initialTarget(_ ws: Workspace, store st: ProjectStore) -> (Scene, EditTarget, Int) {
        switch ws {
        case .motion:
            if let s = st.orderedScenes.first { return (s, .scene(s.id), s.rev) }
        case .thumbnail:
            if let p = st.orderedThumbnails.first, let a = p.artboards.first {
                return (a.asScene(thumbnail: p.id, rev: p.rev), .artboard(thumbnail: p.id, artboard: a.id), p.rev)
            }
        }
        return (placeholderScene(), .none, 0)
    }

    var isThumbnail: Bool { workspace == .thumbnail }
    var isEmptyWorkspace: Bool { target == .none }

    /// The open thumbnail page as stored (the working artboard is `scene`).
    var openThumbnail: Thumbnail? { target.thumbnailId.flatMap { store.thumbnails[$0] } }

    var thumbnails: [Thumbnail] { store.orderedThumbnails }

    /// The stored project, with the open thumbnail's detached theme over it.
    func effectiveProject() -> Project {
        if let p = openThumbnail { return store.project.rendering(p) }
        return store.project
    }

    /// Whether the open thumbnail has its own theme (theme edits then go to it, not to the project).
    var themeIsDetached: Bool { openThumbnail?.theme.isDetached ?? false }

    // MARK: Workspace

    func setWorkspace(_ ws: Workspace) {
        guard ws != workspace else { return }
        saveNow()
        workspace = ws
        var p = store.project
        p.workspace = ws.rawValue
        try? store.update(project: p)
        let (s, t, rev) = EditorDocument.initialTarget(ws, store: store)
        open(s, target: t, rev: rev)
    }

    /// Makes `s` the working copy for `t`, with fresh per-target state (see `switchTo`).
    func open(_ s: Scene, target t: EditTarget, rev: Int) {
        target = t
        switchTo(s)
        baseRev = rev
        project = effectiveProject()
        stateChanged()
    }

    // MARK: Pages & artboards

    func open(thumbnail id: String, artboard: String? = nil) {
        saveNow()
        guard let p = store.thumbnails[id], let a = p.artboard(artboard) ?? p.artboards.first else { return }
        open(a.asScene(thumbnail: p.id, rev: p.rev), target: .artboard(thumbnail: p.id, artboard: a.id), rev: p.rev)
    }

    /// Opens a scene id from the activity feed or history, which may name an artboard (`<thumbnail>~<artboard>`).
    func open(sceneOrArtboard id: String) -> Bool {
        if let r = id.range(of: "~") {
            let p = String(id[..<r.lowerBound]), a = String(id[r.upperBound...])
            guard store.thumbnails[p]?.artboard(a) != nil else { return false }
            if workspace != .thumbnail { workspace = .thumbnail }
            open(thumbnail: p, artboard: a)
            return true
        }
        guard store.scenes[id] != nil else { return false }
        if workspace != .motion { workspace = .motion }
        open(scene: id)
        return true
    }

    func newThumbnail() {
        saveNow()
        var k = store.thumbnails.count + 1
        while store.thumbnails["thumbnail-\(k)"] != nil { k += 1 }
        let p = EditorDocument.starterThumbnail(id: "thumbnail-\(k)", name: "Thumbnail \(k)")
        if let saved = try? store.save(thumbnail: p, summary: "create", source: .editor) {
            refreshProject()
            if workspace != .thumbnail { workspace = .thumbnail }
            open(thumbnail: saved.id)
        }
    }

    /// Runs page ops (`ThumbnailOps`) on a stored thumbnail, saving the working artboard first, then reopens
    /// `reopen` (default: the artboard that was open, or the page's first if it was removed).
    @discardableResult
    func applyPage(_ id: String, _ ops: [JSONValue], summary: String? = nil, reopen: String? = nil) -> Bool {
        saveNow()
        guard let p = store.thumbnails[id] else { return false }
        do {
            let r = try ThumbnailOps.apply(ops, to: p)
            let saved = try store.save(thumbnail: r.thumbnail, summary: summary ?? r.summary, source: .editor)
            ActivityLog.append(
                ActivityEntry(
                    source: .editor, tool: "edit", scene: nil, summary: "\(saved.id): \(summary ?? r.summary)",
                    changed: r.changed, revBefore: p.rev, revAfter: saved.rev, write: true), project: url)
            refreshProject()
            if target.thumbnailId == id || reopen != nil {
                let want = reopen ?? target.artboardId
                open(thumbnail: id, artboard: saved.artboard(want) != nil ? want : nil)
            }
            return true
        } catch {
            flash("\(error)")
            return false
        }
    }

    func addArtboard(preset: ArtboardPresets.Preset, to id: String? = nil) {
        guard let pid = id ?? target.thumbnailId, let p = store.thumbnails[pid] else { return }
        let aid = p.uniqueArtboardId(preset.id)
        applyPage(
            pid,
            [
                [
                    "op": "artboard_add", "id": .string(aid),
                    "name": .string(preset.title.components(separatedBy: " · ")[0]),
                    "size": .array(preset.size.map { .number(Double($0)) }),
                ]
            ],
            summary: "add artboard \(aid)", reopen: aid)
    }

    /// A variant: same layers, placed to the right, named B, C, D…
    func duplicateArtboard(_ aid: String, in pid: String) {
        guard let p = store.thumbnails[pid], let a = p.artboard(aid) else { return }
        let letters = (66...90).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        let used = Set(p.artboards.compactMap(\.name))
        let name = letters.first { !used.contains($0) } ?? ((a.name ?? aid) + " copy")
        let newId = p.uniqueArtboardId(name.lowercased().replacingOccurrences(of: " ", with: "-"))
        applyPage(
            pid, [["op": "artboard_duplicate", "id": .string(aid), "as": .string(newId), "name": .string(name)]],
            summary: "variant \(newId) of \(aid)", reopen: newId)
    }

    func deleteArtboard(_ aid: String, in pid: String) {
        guard let p = store.thumbnails[pid] else { return }
        guard p.artboards.count > 1 else {
            flash("A thumbnail needs at least one artboard — delete the thumbnail instead"); return
        }
        applyPage(pid, [["op": "artboard_remove", "id": .string(aid)]], summary: "remove artboard \(aid)")
    }

    func renameArtboard(_ aid: String, in pid: String, _ name: String) {
        if target == .artboard(thumbnail: pid, artboard: aid) {
            edit { $0.name = name.isEmpty ? nil : name }; saveNow(); return
        }
        applyPage(pid, [["op": "artboard_set", "id": .string(aid), "name": name.isEmpty ? .null : .string(name)]])
    }

    func renameThumbnail(_ pid: String, _ name: String) {
        applyPage(pid, [["op": "thumbnail", "name": name.isEmpty ? .null : .string(name)]], summary: "rename")
    }

    func duplicateThumbnail(_ pid: String) {
        saveNow()
        guard var p = store.thumbnails[pid] else { return }
        var k = 2
        while store.thumbnails["\(pid)-\(k)"] != nil { k += 1 }
        p.id = "\(pid)-\(k)"; p.rev = 0; p.name = (p.name ?? pid) + " copy"
        if let saved = try? store.save(thumbnail: p, summary: "duplicate", source: .editor) {
            refreshProject(); open(thumbnail: saved.id)
        }
    }

    func deleteThumbnail(_ pid: String) {
        try? store.deleteThumbnail(pid)
        refreshProject()
        if target.thumbnailId == pid {
            let (s, t, rev) = EditorDocument.initialTarget(.thumbnail, store: store)
            open(s, target: t, rev: rev)
        }
    }

    // MARK: Theme link

    /// Gives the open thumbnail its own copy of the theme; project theme changes no longer reach it.
    func detachTheme() {
        guard let p = openThumbnail, !p.theme.isDetached else { return }
        applyPage(
            p.id, [["op": "thumbnail", "theme": ["detached": true, "tokens": .object(store.project.theme)]]],
            summary: "detach theme")
        flash("This thumbnail now has its own theme")
    }

    /// Links the open thumbnail back to the project theme (its own tokens are dropped; undo via History).
    func relinkTheme() {
        guard let p = openThumbnail, p.theme.isDetached else { return }
        applyPage(p.id, [["op": "thumbnail", "theme": "project"]], summary: "link theme to project")
        flash("Theme linked to the project again")
    }

    /// Theme edits while a detached thumbnail is open: saved as that thumbnail's tokens.
    func writeDetachedTheme(_ theme: [String: JSONValue]) -> Bool {
        guard let p = openThumbnail, p.theme.isDetached else { return false }
        applyPage(
            p.id, [["op": "thumbnail", "theme": ["detached": true, "tokens": .object(theme)]]], summary: "theme")
        return true
    }

    // MARK: Templates, variants, frames, references

    /// A new artboard from a (thumbnail) template on the open page, or a new page when none is open.
    func newArtboard(from t: Template, params: [String: JSONValue]) {
        saveNow()
        do {
            addTokens(for: t)
            var p: ArclightCore.Thumbnail
            if let open = openThumbnail {
                p = open
            } else {
                var k = store.thumbnails.count + 1
                while store.thumbnails["thumbnail-\(k)"] != nil { k += 1 }
                p = ArclightCore.Thumbnail(id: "thumbnail-\(k)", name: t.name)
            }
            let aid = p.uniqueArtboardId(String(t.id.replacingOccurrences(of: "thumb-", with: "").prefix(24)))
            var a = try Templates.instantiateArtboard(t, params: params, artboardId: aid, store: store)
            (a.x, a.y) = p.nextArtboardOrigin()
            p.artboards.append(a)
            let saved = try store.save(thumbnail: p, summary: "template \(t.id)", source: .editor)
            refreshProject()
            if workspace != .thumbnail { workspace = .thumbnail }
            open(thumbnail: saved.id, artboard: aid)
            libraryVersion += 1
            flash("New artboard from \(t.name)")
        } catch { flash("\(error)") }
    }

    /// Automatic A/B variants of the open artboard, each changing one thing.
    func makeVariants(_ axis: ThumbnailVariants.Axis, count: Int = 2) {
        saveNow()
        guard let p = openThumbnail, let aid = target.artboardId else { return }
        do {
            let (np, ids) = try ThumbnailVariants.makeAuto(axis, count: count, of: aid, in: p)
            _ = try store.save(
                thumbnail: np, expectedRev: p.rev, summary: "variants (\(axis.rawValue)) of \(aid)", source: .editor)
            refreshProject()
            open(thumbnail: p.id, artboard: aid)
            postBoard(.fitAll)
            flash("Added \(ids.count) \(axis.rawValue) variants — export the page to get the set")
        } catch { flash("\(error)") }
    }

    /// Puts a still (asset) into the open artboard as a full-bleed background layer.
    func placeBackground(asset: String) {
        let w = canvasSize.width, h = canvasSize.height
        let id = SceneOps.uniqueId("frame", in: scene)
        apply([
            [
                "op": "add", "index": 0,
                "node": [
                    "id": .string(id), "type": "image", "src": .string(asset), "x": .number(w / 2), "y": .number(h / 2),
                    "width": .number(w), "height": .number(h), "fit": "cover",
                ],
            ]
        ])
        selection = id
    }

    /// Picks a video and places its best frame (sharpest, best face) as the background.
    func frameFromVideo() {
        guard let url = FilePicker.files([.movie]).first else { return }
        let st = store
        busy = "Finding the best frame…"
        Task.detached {
            do {
                let f = try await FrameExtractor.best(video: url, count: 1, store: st)
                await MainActor.run {
                    self.busy = nil
                    if let first = f.first {
                        self.placeBackground(asset: first.asset); self.flash("Frame at \(fmt(first.time)) s")
                    }
                }
            } catch {
                await MainActor.run {
                    self.busy = nil; self.flash("\(error)")
                }
            }
        }
    }

    /// A motion scene rendered at its middle, as the background.
    func snapshotScene(_ id: String) {
        guard let s = store.scenes[id] else { return }
        do {
            let r = try Renderer()
            let f = try FrameExtractor.snapshot(scene: s, time: nil, project: store.project, store: store, renderer: r)
            placeBackground(asset: f.asset)
        } catch { flash("\(error)") }
    }

    /// Adds a reference picture (file, or a YouTube link's thumbnail) to the open page.
    func addReference(_ source: String) {
        guard let p = openThumbnail else { return }
        let st = store
        busy = "Adding reference…"
        Task.detached {
            do {
                let name: String
                if let yt = ReferenceAnalyzer.youtubeID(source) {
                    let data = try await ReferenceAnalyzer.fetchYouTubeThumbnail(yt)
                    name = try AssetWriter.writeImage(data, name: "ref-\(yt).jpg", to: st).src
                } else {
                    name = try st.importAsset(from: URL(fileURLWithPath: source))
                }
                await MainActor.run {
                    self.busy = nil
                    let refs = (p.references ?? []).filter { $0 != name } + [name]
                    self.applyPage(
                        p.id, [["op": "thumbnail", "references": .array(refs.map { .string($0) })]],
                        summary: "reference \(name)")
                }
            } catch {
                await MainActor.run {
                    self.busy = nil; self.flash("\(error)")
                }
            }
        }
    }

    func removeReference(_ name: String) {
        guard let p = openThumbnail else { return }
        let refs = (p.references ?? []).filter { $0 != name }
        applyPage(
            p.id, [["op": "thumbnail", "references": .array(refs.map { .string($0) })]], summary: "remove reference")
    }

    /// Takes a reference's palette into this page's own theme: background, text and accent.
    func applyPalette(_ r: ReferenceAnalyzer.Report) {
        let cols = r.palette.compactMap { c in RGBA.parse(.string(c)).map { (c, ReferenceAnalyzer.luminance($0)) } }
        guard let dark = cols.min(by: { $0.1 < $1.1 }), let light = cols.max(by: { $0.1 < $1.1 }) else { return }
        // Accent: the most saturated remaining colour.
        func sat(_ hex: String) -> Double {
            guard let c = RGBA.parse(.string(hex)) else { return 0 }
            return max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
        }
        let accent = r.palette.filter { $0 != dark.0 && $0 != light.0 }.max { sat($0) < sat($1) } ?? light.0
        if !themeIsDetached { detachTheme() }
        var t = project.theme
        t["bg"] = .string(dark.0); t["fg"] = .string(light.0); t["accent"] = .string(accent)
        _ = writeDetachedTheme(t)
        flash("This page now uses the reference's colours (its own theme)")
    }
}
