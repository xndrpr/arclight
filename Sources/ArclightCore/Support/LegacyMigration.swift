import Foundation

/// One-time carry-over from the app's previous name, Apogee: the hidden project folder, the Application Support and
/// Logs folders, and the settings domain. Every step copies, so the old data stays where it was.
public enum LegacyMigration {
    /// The hidden per-project folder (activity log, notes).
    public static let hiddenFolder = ".arclight"
    static let legacyHiddenFolder = ".apogee"

    /// Copies `<project>/.apogee/` to `<project>/.arclight/` when only the old folder exists.
    public static func migrateHiddenFolder(in project: URL) {
        copyOnce(
            from: project.appendingPathComponent(legacyHiddenFolder), to: project.appendingPathComponent(hiddenFolder))
    }

    /// Marks an Arclight user folder that the Apogee folder has been copied into.
    static let migratedMarker = ".migrated-from-apogee"

    /// Copies `~/Library/Application Support/Apogee` and `~/Library/Logs/Apogee` into their Arclight names, once.
    /// The Arclight folders may already exist (the MCP server or CLI writes presence files there first), so this
    /// merges instead of skipping. `library` is the user's Library folder (injected by tests).
    public static func migrateUserFolders(
        library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    ) {
        for parent in ["Application Support", "Logs"] {
            let dir = library.appendingPathComponent(parent)
            mergeOnce(from: dir.appendingPathComponent("Apogee"), into: dir.appendingPathComponent("Arclight"))
        }
    }

    /// Copies each top-level item of `old` that `new` doesn't have (never overwriting), then writes the marker file
    /// in `new`. Does nothing when `old` is missing or the marker exists. The marker is written only when every copy
    /// succeeded, so a failed item is retried next time. Returns whether it ran.
    @discardableResult
    static func mergeOnce(from old: URL, into new: URL) -> Bool {
        let fm = FileManager.default
        let marker = new.appendingPathComponent(migratedMarker)
        guard !fm.fileExists(atPath: marker.path),
            let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil),
            (try? fm.createDirectory(at: new, withIntermediateDirectories: true)) != nil
        else { return false }
        var copiedAll = true
        for item in items {
            let dest = new.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            if (try? fm.copyItem(at: item, to: dest)) == nil { copiedAll = false }
        }
        if copiedAll { fm.createFile(atPath: marker.path, contents: nil) }
        return true
    }

    /// Fills the settings domain `domain` from the old app's domain (`old`, by default `legacyDomain(for:)`) when
    /// `domain` has no settings of its own. Returns whether anything was copied.
    @discardableResult
    public static func migrateDefaults(
        domain: String, from old: String? = nil, defaults: UserDefaults = .standard
    ) -> Bool {
        guard let old = old ?? legacyDomain(for: domain),
            defaults.persistentDomain(forName: domain)?.isEmpty ?? true,
            let values = defaults.persistentDomain(forName: old), !values.isEmpty
        else { return false }
        defaults.setPersistentDomain(values, forName: domain)
        return true
    }

    /// The old name of a settings domain: the bundle id for the app, the executable name for the CLI.
    public static func legacyDomain(for domain: String) -> String? {
        switch domain {
        case "com.xndrpr.arclight": return "com.xndrpr.apogee"
        case "arclight": return "apogee"
        default: return nil
        }
    }

    /// Copies `old` to `new` when `old` exists and `new` doesn't (best effort). Returns whether it copied.
    @discardableResult
    static func copyOnce(from old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.copyItem(at: old, to: new)) != nil
    }
}
