import AppKit
import ArclightCore
import Foundation

/// Design-system actions on the open document: scenes from templates, inserting templates and symbols,
/// assets (images, audio, fonts, symbol packs), saving templates.
extension EditorDocument {
    /// Adds the theme tokens a template expects (never overwrites the project's).
    func addTokens(for t: Template) {
        let missing = LibraryModel.missingTokens(t, in: store.project)
        guard !missing.isEmpty else { return }
        var p = store.project
        for (k, v) in missing { p.theme[k] = v }
        try? store.update(project: p)
        refreshProject()
    }

    /// Canvas used for new scenes (the project's).
    var projectCanvas: (Int, Int) { (project.size.first ?? 1920, project.size.count > 1 ? project.size[1] : 1080) }

    /// Creates a new scene from a template and opens it.
    func newScene(from t: Template, params: [String: JSONValue]) {
        saveNow()
        let base = LibraryModel.prefix(for: t)
        var id = base, k = 2
        while store.scenes[id] != nil { id = "\(base)-\(k)"; k += 1 }
        do {
            addTokens(for: t)
            var s = try Templates.instantiate(t, params: params, sceneId: id, canvas: projectCanvas)
            s.rev = 0
            let saved = try store.save(scene: s, summary: "template \(t.id)", source: .editor)
            ActivityLog.append(
                ActivityEntry(
                    source: .editor, tool: "template", scene: saved.id, summary: "new scene from template \(t.name)",
                    changed: saved.nodes.map(\.id), revBefore: nil, revAfter: saved.rev, write: true), project: url)
            refreshProject()
            open(scene: saved.id)
            flash("New scene from \(t.name)")
        } catch { flash("\(error)") }
    }

    /// Inserts a template's layers into the current scene (undoable).
    func insertTemplate(_ t: Template, params: [String: JSONValue]) {
        do {
            addTokens(for: t)
            let (cw, ch) = project.size(for: scene)
            let src = try Templates.instantiate(t, params: params, sceneId: "insert", canvas: (cw, ch))
            let r = LibraryModel.insert(src, into: scene, prefix: LibraryModel.prefix(for: t))
            edit { $0 = r.scene }
            selection = r.ids.last
            multiSelection = []
            flash("Inserted \(t.name) · \(r.ids.count) layers")
        } catch { flash("\(error)") }
    }

    /// Adds a repeater (a grid of the symbol on the 3D floor), with a camera when the scene has none.
    func addRepeater(symbol: String) {
        addNode(
            "repeater",
            props: [
                "x": 960, "y": 830, "z": 1500, "cols": 16, "rows": 10, "spacing": 110, "jitter": 0.15,
                "items": [["symbol": .string(symbol), "height": 100]],
            ])
        if scene.camera == nil {
            edit { $0.camera = .value(["position": [760, 60, -380], "target": [1000, 830, 1500], "fov": 40]) }
        }
    }

    /// Adds one symbol as its own 2D layer (centred, theme colour), like any shape.
    func addSymbolLayer(_ symbol: String) {
        let (cw, ch) = project.size(for: scene)
        let name = symbol.split(separator: "/").last.map(String.init) ?? "symbol"
        addNode(
            "symbol",
            props: [
                "symbol": .string(symbol), "size": .number((Double(min(cw, ch)) * 0.3).rounded()),
                "x": .number(Double(cw) / 2), "y": .number(Double(ch) / 2), "fill": "$fg",
            ], idBase: name)
    }

    /// The selected layer, when it is a repeater.
    var selectedRepeater: String? {
        guard let id = selection, scene.node(id)?.type == "repeater" else { return nil }
        return id
    }

    /// Adds `{"symbol": id, "height": 100}` to the selected repeater's items.
    func useSymbolInSelectedRepeater(_ symbol: String) {
        guard let id = selectedRepeater else { addSymbolLayer(symbol); return }
        edit { s in
            guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
            var items: [JSONValue] = []
            if case .value(let v)? = s.nodes[i].props["items"], let a = v.array { items = a }
            items.append(["symbol": .string(symbol), "height": 100])
            s.nodes[i].props["items"] = .value(.array(items))
        }
        flash("Added \(symbol) to \(id)")
    }

    /// Adds an image layer for a file in assets/, centred and fitted to half the canvas width.
    func addImageLayer(_ name: String) {
        let (cw, ch) = project.size(for: scene)
        addNode(
            "image",
            props: [
                "src": .string(name), "x": .number(Double(cw) / 2), "y": .number(Double(ch) / 2),
                "width": .number(Double(cw) / 2),
            ])
    }

    /// Sets the scene's reference audio (keeps offset/gain when replacing a file).
    func useAsSceneAudio(_ name: String) {
        edit { s in
            var a = s.audio ?? AudioRef(src: name)
            a.src = name
            s.audio = a
        }
        flash("Scene audio: \(name)")
    }

    /// Asks for files and copies each into the right project folder.
    func importAssetsWithPanel() {
        let urls = FilePicker.files(
            multiple: true, message: "Images and audio go to assets/, fonts to fonts/, symbol packs (.json) to symbols/"
        )
        if !urls.isEmpty { importAssets(urls) }
    }

    func importAssets(_ urls: [URL]) {
        var done = 0, failed: [String] = []
        for u in urls {
            do { try LibraryModel.importFile(u, into: url); done += 1 } catch { failed.append(u.lastPathComponent) }
        }
        libraryVersion += 1
        if failed.isEmpty {
            flash("Imported \(done) file\(done == 1 ? "" : "s")")
        } else {
            flash("Imported \(done), skipped \(failed.joined(separator: ", "))")
        }
    }

    /// Deletes a template file (project or user library) after confirmation.
    func deleteTemplate(_ f: LibraryModel.TemplateFile) {
        let a = NSAlert()
        a.messageText = "Delete template “\(f.template.name)”?"
        a.informativeText =
            f.scope == .user ? "It is removed from all projects (moved to the Trash)." : "It is moved to the Trash."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: f.url, resultingItemURL: nil); libraryVersion += 1;
            flash("Deleted template \(f.template.id)")
        } catch { flash("\(error)") }
    }

    /// Saves a template built from the current/other scene.
    func saveTemplate(
        from s: Scene, id: String, name: String, description: String?, category: String?,
        scope: Templates.Scope, picks: [LibraryModel.ParamCandidate]
    ) -> Bool {
        if s.id == scene.id { saveNow() }
        do {
            let t = try LibraryModel.makeTemplate(
                from: s, id: id, name: name, description: description, category: category, picks: picks)
            _ = try Templates.save(t, scope: scope, project: url)
            libraryVersion += 1
            flash("Saved template \(t.name)\(scope == .user ? " (all projects)" : "")")
            return true
        } catch { flash("\(error)"); return false }
    }
}
