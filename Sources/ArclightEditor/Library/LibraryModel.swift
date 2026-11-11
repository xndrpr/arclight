import ArclightCore
import Foundation

/// Editor-side logic for the design system (templates, symbols, assets) that does not need a window, kept free of
/// SwiftUI so it can be unit-tested. This file: new projects and form values. Asset import and classification are
/// in LibraryAssets.swift; template files, inserting a template and the "save as template" picker in
/// LibraryTemplates.swift.
enum LibraryModel {

    // MARK: New project

    /// Creates `<dir>/<name>.arclight` with the canvas and frame rate, and a first scene: the template instantiated
    /// with its defaults (theme tokens it needs are added), or an empty 5 s scene.
    static func createProject(
        in dir: URL, name: String, size: (Int, Int), fps: Double, template: Template?
    ) throws -> URL {
        let clean =
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name.trimmingCharacters(in: .whitespaces)
        let url = dir.appendingPathComponent(
            clean.hasSuffix(".arclight") || clean.hasSuffix(".apogee") ? clean : clean + ".arclight")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw ModelError.invalid("\(url.lastPathComponent) already exists in \(dir.path)")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try ProjectStore.create(at: url, name: (clean as NSString).deletingPathExtension)
        var p = store.project
        p.size = [size.0, size.1]
        p.fps = fps
        if let t = template { for (k, v) in missingTokens(t, in: p) { p.theme[k] = v } }
        try store.update(project: p)
        var scene: Scene
        if let t = template {
            scene = try Templates.instantiate(
                t, params: [:], sceneId: slug(t.id).isEmpty ? "scene-1" : slug(t.id), canvas: size)
            scene.rev = 0
        } else {
            scene = Scene(id: "scene-1", duration: 5)
            scene.name = "Scene 1"; scene.background = .value("$bg")
        }
        try store.save(scene: scene, summary: template.map { "template \($0.id)" } ?? "create", source: .editor)
        return url
    }

    /// Default location for new projects.
    static var defaultProjectsDir: URL {
        AppPaths.defaultProjects
    }

    /// Parses a form value for a param kind ("number" → number, "json" → any JSON, else string).
    static func value(_ text: String, kind: String?) -> JSONValue? {
        switch kind {
        case "number": return Double(text.trimmingCharacters(in: .whitespaces)).map { .number($0) }
        case "json": return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        default: return .string(text)
        }
    }

    /// Text shown in a form field for a JSON value.
    static func text(_ v: JSONValue?, kind: String?) -> String {
        guard let v else { return "" }
        let json = { (try? String(data: JSONFormat.compact().encode(v), encoding: .utf8)) ?? "" }
        if kind == "json" { return json() }
        if let s = v.string { return s }
        if let d = v.double { return d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d) }
        return json()
    }
}
