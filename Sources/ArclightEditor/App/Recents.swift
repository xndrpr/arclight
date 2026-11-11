import ArclightCore
import Foundation

enum Recents {
    static var all: [URL] {
        (Pref.store.stringArray(forKey: Pref.recentProjects) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
    }
    static func remove(_ url: URL) {
        Pref.store.set(
            (Pref.store.stringArray(forKey: Pref.recentProjects) ?? []).filter { $0 != url.path },
            forKey: Pref.recentProjects)
    }
    /// Display name from project.json (falls back to the folder name).
    static func name(_ url: URL) -> String {
        if let d = try? Data(contentsOf: url.appendingPathComponent("project.json")),
            let p = try? JSONDecoder().decode(Project.self, from: d)
        {
            return p.name
        }
        return url.deletingPathExtension().lastPathComponent
    }
    static func add(_ url: URL) {
        var list = (Pref.store.stringArray(forKey: Pref.recentProjects) ?? []).filter { $0 != url.path }
        list.insert(url.path, at: 0)
        Pref.store.set(Array(list.prefix(12)), forKey: Pref.recentProjects)
    }
}
