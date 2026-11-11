import CoreText
import Foundation

/// A project on disk:
/// ```
/// Name.arclight/        (or Name.apogee/, the old extension)
///   project.json
///   scenes/<id>.json
///   assets/
///   .arclight/          activity log and notes (copied once from an old .apogee/)
/// ```
public final class ProjectStore {
    public let url: URL
    public private(set) var project: Project
    public private(set) var scenes: [String: Scene]

    public var assetsURL: URL { url.appendingPathComponent("assets") }
    var scenesURL: URL { url.appendingPathComponent("scenes") }

    public init(url: URL) throws {
        self.url = url
        project = Project(name: "")
        scenes = [:]
        try reload()
        LegacyMigration.migrateHiddenFolder(in: url)
    }

    /// Fonts in `<project>/fonts` are registered for this process so projects render the same on any Mac.
    private static var registeredFonts = Set<String>()
    public static func registerFonts(in project: URL) {
        let dir = project.appendingPathComponent("fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files
        where ["ttf", "otf", "ttc"].contains(f.pathExtension.lowercased()) && !registeredFonts.contains(f.path) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            registeredFonts.insert(f.path)
        }
    }

    /// Re-reads everything from disk (the editor and the MCP server both write).
    public func reload() throws {
        ProjectStore.registerFonts(in: url)
        let pdata = try Data(contentsOf: url.appendingPathComponent("project.json"))
        project = try JSONDecoder().decode(Project.self, from: pdata)
        scenes = [:]
        let fm = FileManager.default
        let files =
            (try? fm.contentsOfDirectory(at: url.appendingPathComponent("scenes"), includingPropertiesForKeys: nil))
            ?? []
        for f in files where f.pathExtension == "json" {
            do {
                let s = try JSONDecoder().decode(Scene.self, from: Data(contentsOf: f))
                scenes[s.id] = s
            } catch {
                throw ModelError.invalid("\(f.lastPathComponent): \(error)")
            }
        }
        // Scene order follows project.json, with scenes found on disk appended.
        let known = Set(scenes.keys)
        project.scenes = project.scenes.filter(known.contains) + known.subtracting(project.scenes).sorted()
    }

    public static func create(at url: URL, name: String) throws -> ProjectStore {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("scenes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try ProjectStore.write(Project(name: name), to: url.appendingPathComponent("project.json"))
        return try ProjectStore(url: url)
    }

    public var orderedScenes: [Scene] { project.scenes.compactMap { scenes[$0] } }

    public func scene(_ id: String?) throws -> Scene {
        if let id { guard let s = scenes[id] else { throw ModelError.notFound("scene '\(id)'") }; return s }
        guard let first = orderedScenes.first else { throw ModelError.notFound("project has no scenes") }
        return first
    }

    /// Saves a scene, bumping `rev`, and records a history snapshot. Pass `expectedRev` to reject writes based on a
    /// stale copy.
    @discardableResult
    public func save(
        scene: Scene, expectedRev: Int? = nil, summary: String = "edit", source: ChangeSource = .cli
    ) throws -> Scene {
        try SafeName.component(scene.id, what: "scene id")
        let current = scenes[scene.id]
        if let expectedRev, let cur = current, cur.rev != expectedRev {
            throw ModelError.invalid(
                "scene '\(scene.id)' changed (rev \(cur.rev), expected \(expectedRev)); re-read it")
        }
        if let cur = current, !FileManager.default.fileExists(atPath: historyFile(cur.id, cur.rev).path) {
            snapshot(cur, summary: "before", source: source.rawValue, changed: nil)
        }
        var s = scene
        s.rev = (current?.rev ?? scene.rev) + 1
        try ProjectStore.write(s, to: scenesURL.appendingPathComponent("\(s.id).json"))
        let diff = SceneDiff.diff(current, s)
        scenes[s.id] = s
        snapshot(s, summary: summary, source: source.rawValue, changed: diff.all)
        if !project.scenes.contains(s.id) { project.scenes.append(s.id); try saveProject() }
        return s
    }

    // MARK: History — .history/<scene>/<rev>.json plus log.jsonl

    public struct HistoryEntry: Codable, Sendable, Identifiable {
        public var rev: Int
        public var time: String
        public var summary: String
        /// A `ChangeSource` raw value (nil in projects saved before this was recorded).
        public var source: String?
        public var changed: [String]?
        public var id: Int { rev }
    }

    /// The saved snapshot of a revision, if it is still kept.
    public func snapshot(_ id: String, rev: Int) -> Scene? {
        guard SafeName.isComponent(id) else { return nil }
        return JSONFile.read(Scene.self, from: historyFile(id, rev))
    }

    static let historyLimit = 200

    func historyDir(_ id: String) -> URL { url.appendingPathComponent(".history").appendingPathComponent(id) }
    func historyFile(_ id: String, _ rev: Int) -> URL { historyDir(id).appendingPathComponent("\(rev).json") }

    /// History logs keep the default encoder and whole-second times: existing logs must stay readable and uniform.
    func snapshot(_ s: Scene, summary: String, source: String? = nil, changed: [String]? = nil) {
        let dir = historyDir(s.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? ProjectStore.write(s, to: historyFile(s.id, s.rev))
        let e = HistoryEntry(
            rev: s.rev, time: ISO8601DateFormatter().string(from: Date()), summary: summary,
            source: source, changed: changed?.isEmpty == true ? nil : changed)
        JSONL.append(e, to: dir.appendingPathComponent("log.jsonl"), encoder: JSONEncoder())
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap {
            Int($0.replacingOccurrences(of: ".json", with: ""))
        }.sorted()
        for r in files.dropLast(ProjectStore.historyLimit) {
            try? FileManager.default.removeItem(at: historyFile(s.id, r))
        }
    }

    public func history(_ id: String) -> [HistoryEntry] {
        guard SafeName.isComponent(id),
            let data = try? String(contentsOf: historyDir(id).appendingPathComponent("log.jsonl"), encoding: .utf8)
        else { return [] }
        let all = data.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(HistoryEntry.self, from: Data($0.utf8))
        }
        return all.filter { FileManager.default.fileExists(atPath: historyFile(id, $0.rev).path) }
    }

    /// Restores a snapshot as a new revision (history is never rewritten).
    @discardableResult
    public func revert(_ id: String, to rev: Int, source: ChangeSource = .cli) throws -> Scene {
        try SafeName.component(id, what: "scene id")
        guard let data = try? Data(contentsOf: historyFile(id, rev)) else {
            throw ModelError.notFound("rev \(rev) of '\(id)'")
        }
        let old = try JSONDecoder().decode(Scene.self, from: data)
        return try save(scene: old, summary: "revert to \(rev)", source: source)
    }

    /// Copies a file into assets/ and returns the name to use as `src`.
    public func importAsset(from src: URL, name: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let n = try SafeName.component(name ?? src.lastPathComponent, what: "asset name")
        let dest = assetsURL.appendingPathComponent(n)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Importing a file that already is this asset (same path, a symlink, or a case-only difference on a
            // case-insensitive volume) must not delete it.
            if ProjectStore.sameFile(src, dest) { return n }
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        return n
    }

    /// Whether two URLs name the same file on disk (compared by file identity, not by path).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        func identity(_ u: URL) -> (any NSObjectProtocol)? {
            (try? u.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier as? any NSObjectProtocol
        }
        guard let x = identity(a), let y = identity(b) else {
            return a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
        }
        return x.isEqual(y)
    }

    public func deleteScene(_ id: String) throws {
        try SafeName.component(id, what: "scene id")
        try? FileManager.default.removeItem(at: scenesURL.appendingPathComponent("\(id).json"))
        scenes[id] = nil
        project.scenes.removeAll { $0 == id }
        try saveProject()
    }

    public func update(project p: Project) throws { project = p; try saveProject() }

    func saveProject() throws { try ProjectStore.write(project, to: url.appendingPathComponent("project.json")) }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONFormat.pretty().encode(value).write(to: url, options: .atomic)
    }
}
