import AppKit
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor
@testable import ArclightMCP

@Suite(.serialized) struct ThemePresetTests {
    /// Points the user preset library at a fresh temp folder for the test.
    func withTempLibrary(_ body: () throws -> Void) rethrows {
        let saved = ThemePresets.userDir
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-themes-\(UUID().uuidString)")
        ThemePresets.userDir = dir
        defer { ThemePresets.userDir = saved; try? FileManager.default.removeItem(at: dir) }
        try body()
    }

    @Test func builtInsDefineStandardTokensWithInstalledFonts() {
        #expect(ThemePresets.builtIn.count >= 10)
        #expect(Set(ThemePresets.builtIn.map(\.id)).count == ThemePresets.builtIn.count)
        for p in ThemePresets.builtIn {
            for k in ThemePresets.standardKeys { #expect(p.tokens[k] != nil, "\(p.id) misses $\(k)") }
            for k in ThemePresets.standardKeys where !ThemePresets.fontKeys.contains(k) {
                #expect(RGBA.parse(p.tokens[k]) != nil, "\(p.id) $\(k) is not a colour")
            }
            for k in ThemePresets.fontKeys {
                let f = p.tokens[k]?.string ?? ""
                #expect(NSFont(name: f, size: 12) != nil, "\(p.id) font \(f) is not installed")
            }
        }
        // Every token the built-in templates use (except template-provided ones) exists in each preset.
        for k in ["bg", "fg", "muted", "accent", "display", "body", "pool", "ink"] {
            #expect(ThemePresets.builtIn.allSatisfy { $0.tokens[k] != nil })
        }
    }

    @Test func examplesUseTheirPresets() throws {
        #expect(
            ThemePresets.builtIn.map(\.id) == [
                "mono-black", "paper", "midnight", "editorial", "neon", "vitesse",
                "gruvbox", "pastel", "brutalist", "newspaper", "ember", "glacier",
            ])
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples")
        let expected = [
            "data-bars": "midnight", "kinetic-type": "brutalist", "logo-sting": "glacier", "lower-third": "gruvbox",
            "quote-card": "editorial", "social-vertical": "neon", "spotlight-crowd": "ember",
        ]
        for (name, preset) in expected {
            let store = try ProjectStore(url: examples.appendingPathComponent("\(name).arclight"))
            #expect(
                ThemePresets.builtIn.first { ThemePresets.matches($0, store.project.theme) }?.id == preset, "\(name)")
        }
    }

    @Test func applyKeepsCustomTokens() {
        let theme: [String: JSONValue] = [
            "bg": "#000000", "fg": "#FFFFFF", "whisper": "Georgia-Italic", "piece": "#0B0B0B",
        ]
        let midnight = ThemePresets.get("midnight")!
        let out = ThemePresets.applying(midnight, to: theme)
        #expect(out["bg"] == midnight.tokens["bg"])
        #expect(out["display"] == midnight.tokens["display"])
        #expect(out["whisper"] == "Georgia-Italic")
        #expect(out["piece"] == "#0B0B0B")
        #expect(ThemePresets.current(out)?.id == "midnight")
        #expect(ThemePresets.matches(ThemePresets.get("Mono Black")!, Project.defaultTheme))
        #expect(ThemePresets.current(theme) == nil)
    }

    @Test func saveLoadDeleteRoundTrip() throws {
        try withTempLibrary {
            let tokens: [String: JSONValue] = ["bg": "#101010", "fg": "#EEEEEE", "accent": "#FF0000", "custom": 12]
            let p = try ThemePresets.save(name: "Brand Dark", tokens: tokens, description: "ours")
            #expect(p.id == "brand-dark" && !p.isBuiltIn)
            let loaded = ThemePresets.user()
            #expect(loaded == [p])
            #expect(ThemePresets.get("Brand dark") == p)
            // A name clashing with a built-in never overwrites it.
            let clash = try ThemePresets.save(name: "Neon", tokens: tokens)
            #expect(clash.id == "my-neon")
            #expect(ThemePresets.get("neon")?.isBuiltIn == true)
            #expect(throws: (any Error).self) { try ThemePresets.delete("neon") }
            #expect(throws: (any Error).self) { try ThemePresets.save(name: "  ", tokens: tokens) }
            try ThemePresets.delete(p.id)
            try ThemePresets.delete(clash.id)
            #expect(ThemePresets.user().isEmpty)
        }
    }

    @Test func mcpListApplyAndSave() throws {
        try withTempLibrary {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "arclight-theme-\(UUID().uuidString).arclight")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = try ProjectStore.create(at: url, name: "t")
            var p = store.project
            p.theme["whisper"] = "Georgia-Italic"
            try store.update(project: p)
            let server = MCPServer(projectPath: url.path)
            func run(_ tool: String, _ args: [String: JSONValue]) throws -> String {
                let t = try #require(server.tools.first { $0.name == tool })
                return try t.run(args).compactMap { $0["text"]?.string }.joined()
            }
            let list = try run(MCPServer.themePresetListTool, [:])
            #expect(list.contains("paper") && list.contains("[current]"))
            #expect(try run("theme_apply", ["preset": "Paper"]).contains("applied Paper"))
            let reopened = try ProjectStore(url: url)
            #expect(reopened.project.theme["bg"] == ThemePresets.get("paper")!.tokens["bg"])
            #expect(reopened.project.theme["whisper"] == "Georgia-Italic")
            #expect(throws: (any Error).self) { try run("theme_apply", ["preset": "nope"]) }
            #expect(try run("theme_preset_save", ["name": "Mine"]).contains("saved preset mine"))
            #expect(ThemePresets.get("mine")?.tokens["whisper"] == "Georgia-Italic")
        }
    }

    @Test(.requiresMetal) func editorThemeEditsAreUndoable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-themeui-\(UUID().uuidString).arclight")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try ProjectStore.create(at: url, name: "t")
        EditorDocument.recordRecents = false
        let doc = try EditorDocument(url: url)
        let before = doc.project.theme
        doc.applyThemePreset(ThemePresets.get("neon")!)
        #expect(doc.currentThemePreset?.id == "neon")
        doc.setThemeToken("fg", "#123456")
        doc.setThemeToken("fg", "#654321")  // coalesces with the previous edit of $fg
        #expect(doc.project.theme["fg"] == "#654321")
        #expect(doc.undoTheme())
        #expect(doc.currentThemePreset?.id == "neon")
        #expect(doc.undoTheme())
        #expect(doc.project.theme == before)
        #expect(!doc.canUndoTheme && doc.canRedoTheme)
        #expect(doc.redoTheme())
        #expect(doc.currentThemePreset?.id == "neon")
    }
}
