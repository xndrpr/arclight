import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// Back-compat with projects, folders and settings from before the rename (Apogee).
@Suite struct LegacyMigrationTests {
    func tempDir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-legacy-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// An old project: `.apogee` extension and a hidden `.apogee/` folder with notes and activity.
    func oldProject() throws -> URL {
        let url = try tempDir("Old.apogee")
        try FileManager.default.removeItem(at: url)
        _ = try ProjectStore.create(at: url, name: "Old")
        let hidden = url.appendingPathComponent(".apogee")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data(#"[{"id":"n-1","text":"slower","scene":"s","status":"open","created":"2026-01-01T00:00:00Z"}]"#.utf8)
            .write(to: hidden.appendingPathComponent("notes.json"))
        try Data("{\"summary\":\"old\"}\n".utf8).write(to: hidden.appendingPathComponent("activity.jsonl"))
        return url
    }

    @Test func openingOldProjectCopiesHiddenFolderOnce() throws {
        let url = try oldProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ProjectStore(url: url)
        #expect(store.project.name == "Old")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.appendingPathComponent(".arclight/notes.json").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent(".arclight/activity.jsonl").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent(".apogee/notes.json").path))  // the old one stays
        #expect(Notes.load(project: url).map(\.text) == ["slower"])

        // Once: a later open doesn't overwrite what Arclight wrote since.
        try Notes.save([], project: url)
        _ = try ProjectStore(url: url)
        #expect(Notes.load(project: url).isEmpty)
    }

    @Test func newProjectsUseTheNewHiddenFolder() throws {
        let url = try tempDir("New.arclight")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        _ = try ProjectStore.create(at: url, name: "New")
        _ = try Notes.add(Note(text: "hi", scene: "s"), project: url)
        #expect(Notes.url(url).path.hasSuffix("New.arclight/.arclight/notes.json"))
        #expect(ActivityLog.url(url).path.hasSuffix("New.arclight/.arclight/activity.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(".apogee").path))
    }

    @Test func mcpOpensOldProject() throws {
        let url = try oldProject()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = MCPServer(projectPath: url.path)
        #expect(server.store?.project.name == "Old")
    }

    @Test func userFoldersAreCopiedOnce() throws {
        let library = try tempDir("Library")
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let fm = FileManager.default
        let oldSupport = library.appendingPathComponent("Application Support/Apogee/library/templates")
        let oldLogs = library.appendingPathComponent("Logs/Apogee")
        try fm.createDirectory(at: oldSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldLogs, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: oldSupport.appendingPathComponent("mine.json"))
        try Data("log".utf8).write(to: oldLogs.appendingPathComponent("clicks.log"))

        LegacyMigration.migrateUserFolders(library: library)
        let newSupport = library.appendingPathComponent("Application Support/Arclight/library/templates/mine.json")
        #expect(fm.fileExists(atPath: newSupport.path))
        #expect(fm.fileExists(atPath: library.appendingPathComponent("Logs/Arclight/clicks.log").path))
        #expect(fm.fileExists(atPath: oldSupport.appendingPathComponent("mine.json").path))

        // Once: a folder that already exists is never replaced.
        try fm.removeItem(at: newSupport)
        LegacyMigration.migrateUserFolders(library: library)
        #expect(!fm.fileExists(atPath: newSupport.path))
    }

    @Test func userFoldersMergeIntoAnExistingNewFolder() throws {
        let library = try tempDir("Library")
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let fm = FileManager.default
        let old = library.appendingPathComponent("Application Support/Apogee")
        let new = library.appendingPathComponent("Application Support/Arclight")
        try fm.createDirectory(at: old.appendingPathComponent("library/templates"), withIntermediateDirectories: true)
        try fm.createDirectory(at: old.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("library/templates/mine.json"))
        try Data("old".utf8).write(to: old.appendingPathComponent("agents/a.json"))
        // The MCP server ran first and created the new folder with only presence files.
        try fm.createDirectory(at: new.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: new.appendingPathComponent("agents/b.json"))

        LegacyMigration.migrateUserFolders(library: library)
        #expect(fm.fileExists(atPath: new.appendingPathComponent("library/templates/mine.json").path))
        // Top-level items that already exist are left as they are.
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("agents/a.json").path))
        #expect(try Data(contentsOf: new.appendingPathComponent("agents/b.json")) == Data("new".utf8))
        #expect(fm.fileExists(atPath: old.appendingPathComponent("library/templates/mine.json").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent(LegacyMigration.migratedMarker).path))

        // Once: the marker stops later runs from bringing back what was deleted since.
        try fm.removeItem(at: new.appendingPathComponent("library"))
        LegacyMigration.migrateUserFolders(library: library)
        #expect(!fm.fileExists(atPath: new.appendingPathComponent("library").path))
    }

    @Test func userFolderMergeIsRetriedAfterAFailedCopy() throws {
        let root = try tempDir("Merge")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("Apogee"), new = root.appendingPathComponent("Arclight")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("ok.json"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: new.path)  // read-only: the copy fails
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.path) }

        #expect(LegacyMigration.mergeOnce(from: old, into: new))
        #expect(!fm.fileExists(atPath: new.appendingPathComponent(LegacyMigration.migratedMarker).path))

        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.path)
        #expect(LegacyMigration.mergeOnce(from: old, into: new))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("ok.json").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent(LegacyMigration.migratedMarker).path))
        #expect(!LegacyMigration.mergeOnce(from: old, into: new))
    }

    @Test func userFoldersWithoutOldOnesStayAbsent() throws {
        let library = try tempDir("Library")
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        LegacyMigration.migrateUserFolders(library: library)
        #expect(
            !FileManager.default.fileExists(atPath: library.appendingPathComponent("Application Support/Arclight").path)
        )
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("Logs/Arclight").path))
    }

    @Test func settingsAreReadOnceWhenTheNewDomainIsEmpty() throws {
        let d = UserDefaults.standard
        let defaults = try TempDefaults()
        defer { defaults.remove() }
        let old = defaults.domain("legacyOld"), new = defaults.domain("legacyNew")
        #expect(!LegacyMigration.migrateDefaults(domain: new, from: old, defaults: d))  // nothing to read
        d.setPersistentDomain(["ui.theme": "light", "ui.rowH": 22], forName: old)
        #expect(LegacyMigration.migrateDefaults(domain: new, from: old, defaults: d))
        #expect(d.persistentDomain(forName: new)?["ui.theme"] as? String == "light")
        #expect(d.persistentDomain(forName: new)?["ui.rowH"] as? Int == 22)

        // The new domain has settings of its own now: never overwritten.
        d.setPersistentDomain(["ui.theme": "dark"], forName: new)
        #expect(!LegacyMigration.migrateDefaults(domain: new, from: old, defaults: d))
        #expect(d.persistentDomain(forName: new)?["ui.theme"] as? String == "dark")
    }

    @Test func legacyDomainNames() {
        #expect(LegacyMigration.legacyDomain(for: "com.xndrpr.arclight") == "com.xndrpr.apogee")
        #expect(LegacyMigration.legacyDomain(for: "arclight") == "apogee")
        #expect(LegacyMigration.legacyDomain(for: "verify-cli") == nil)
        #expect(!LegacyMigration.migrateDefaults(domain: "verify-cli"))
    }

    @Test func versionStrings() {
        #expect(ArclightVersion.display == "0.1.0 (alpha)")
    }
}
