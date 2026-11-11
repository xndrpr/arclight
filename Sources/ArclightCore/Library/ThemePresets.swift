import Foundation

/// A named set of project theme tokens (colours and fonts) that restyles every scene in one step.
/// Built-in presets ship with the app; users save their own to `~/Library/Application Support/Arclight/library/themes/*.json`.
public struct ThemePreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var tokens: [String: JSONValue]

    public init(id: String, name: String, description: String? = nil, tokens: [String: JSONValue]) {
        self.id = id; self.name = name; self.description = description; self.tokens = tokens
    }

    /// Shipped with the app (cannot be deleted or overwritten).
    public var isBuiltIn: Bool { ThemePresets.builtIn.contains { $0.id == id } }

    public func color(_ key: String) -> String? { tokens[key]?.string }
}

public enum ThemePresets {
    /// Tokens the built-in templates and examples use. Every built-in preset defines all of them.
    ///   bg / fg / muted — background, main text and secondary text · accent — highlights
    ///   ink — dark figures (crowd symbols) · pool — light-pool / spotlight colour · floor — 3D ground
    ///   display / body — headline and body fonts
    public static let standardKeys = ["bg", "fg", "muted", "accent", "ink", "pool", "floor", "display", "body"]
    public static let fontKeys: Set<String> = ["display", "body"]

    /// Plain-language description of a standard token (UI help, MCP listing).
    public static func describe(_ key: String) -> String? {
        switch key {
        case "bg": return "Background"
        case "fg": return "Main text and shapes"
        case "muted": return "Secondary text"
        case "accent": return "Highlights"
        case "ink": return "Dark figures (crowd symbols)"
        case "pool": return "Spotlight / light-pool colour"
        case "floor": return "3D floor"
        case "display": return "Headline font"
        case "body": return "Body font"
        default: return nil
        }
    }

    /// Fonts used here ship with every Mac (macOS 14+).
    public static let builtIn: [ThemePreset] = [
        p(
            "mono-black", "Mono Black", "The default: warm white on black, condensed Helvetica.",
            "#000000", "#F2EFE6", "#7A7A7A", "#FFFFFF", "#070707", "#FFF6E8", "#0B0B0B", "HelveticaNeue-CondensedBlack",
            "HelveticaNeue-Medium"),
        p(
            "paper", "Paper", "Black on off-white paper — clean and print-like.",
            "#F4F1EA", "#111111", "#6B6B6B", "#000000", "#1A1A1A", "#FFFFFF", "#E4DFD4", "HelveticaNeue-CondensedBlack",
            "HelveticaNeue-Medium"),
        p(
            "midnight", "Midnight", "Deep navy with an electric blue accent.",
            "#0B1020", "#E6ECFF", "#7C88A8", "#5B8CFF", "#04060E", "#CFE0FF", "#0E1530", "AvenirNext-Heavy",
            "AvenirNext-Medium"),
        p(
            "editorial", "Editorial", "Warm cream, espresso ink and a serif headline.",
            "#F3EBDD", "#2A1F17", "#8A7A68", "#B4441F", "#2A1F17", "#FFF4DE", "#E6D9C3", "Didot-Bold", "Georgia"),
        p(
            "neon", "Neon", "Pure black with acid-green highlights.",
            "#050505", "#F5F5F5", "#6E6E6E", "#39FF14", "#000000", "#B6FF9E", "#0A0A0A", "Futura-Bold", "Futura-Medium"),
        p(
            "vitesse", "Vitesse", "Soft charcoal and sage green, monospaced.",
            "#121212", "#DBD7CA", "#758575", "#4D9375", "#0A0A0A", "#E3F1E8", "#181818", "Menlo-Bold", "Menlo-Regular"),
        p(
            "gruvbox", "Gruvbox", "Retro warm dark: cream on brown-black, amber accent.",
            "#282828", "#EBDBB2", "#A89984", "#FABD2F", "#1D2021", "#FBF1C7", "#32302F", "AvenirNextCondensed-Bold",
            "AvenirNextCondensed-Medium"),
        p(
            "pastel", "Pastel", "Soft pink and lavender, friendly rounded type.",
            "#FBF3F6", "#3B3355", "#9A91B0", "#FF8FB1", "#3B3355", "#FFFFFF", "#F1E4EC", "AvenirNext-Bold",
            "AvenirNext-Regular"),
        p(
            "brutalist", "Brutalist", "Black on signal red, heavy poster type.",
            "#E10600", "#000000", "#5C0000", "#FFFFFF", "#000000", "#FFFFFF", "#B80500", "Impact", "HelveticaNeue-Bold"),
        p(
            "newspaper", "Newspaper", "Newsprint grey, black serif and a dark red accent.",
            "#EDE8DC", "#141414", "#5E5A52", "#8B0000", "#141414", "#FFFDF5", "#DCD5C4", "Baskerville-Bold", "Georgia"),
        p(
            "ember", "Ember", "Warm near-black with tangerine light and condensed DIN.",
            "#0E0806", "#FFE9D6", "#6E5A4E", "#FF7A2F", "#0A0605", "#FFB36B", "#140C09", "DINCondensed-Bold",
            "DINAlternate-Bold"),
        p(
            "glacier", "Glacier", "Deep teal-black with an icy aqua accent and Gill Sans.",
            "#071417", "#E8FBF8", "#5F8A8B", "#3DE0C8", "#031012", "#B8FFF4", "#0A1D20", "GillSans-SemiBold",
            "GillSans-Light"),
    ]

    private static func p(
        _ id: String, _ name: String, _ desc: String,
        _ bg: String, _ fg: String, _ muted: String, _ accent: String, _ ink: String, _ pool: String, _ floor: String,
        _ display: String, _ body: String
    ) -> ThemePreset {
        ThemePreset(
            id: id, name: name, description: desc,
            tokens: [
                "bg": .string(bg), "fg": .string(fg), "muted": .string(muted), "accent": .string(accent),
                "ink": .string(ink), "pool": .string(pool), "floor": .string(floor), "display": .string(display),
                "body": .string(body),
            ])
    }

    // MARK: Library

    /// Where user presets live. Overridable for tests.
    nonisolated(unsafe) public static var userDir: URL = AppPaths.library("themes")

    public static func user() -> [ThemePreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            guard let d = try? Data(contentsOf: $0), var t = try? JSONDecoder().decode(ThemePreset.self, from: d) else {
                return nil
            }
            t.id = $0.deletingPathExtension().lastPathComponent
            return builtIn.contains { $0.id == t.id } ? nil : t
        }
    }

    /// Built-in presets first, then the user's.
    public static func all() -> [ThemePreset] { builtIn + user() }

    /// Finds a preset by id or (case-insensitive) name.
    public static func get(_ idOrName: String) -> ThemePreset? {
        let q = idOrName.trimmingCharacters(in: .whitespaces).lowercased()
        let list = all()
        return list.first { $0.id == q } ?? list.first { $0.name.lowercased() == q }
            ?? list.first { slug($0.name) == slug(q) }
    }

    /// Saves `tokens` as a user preset named `name` (replacing a user preset of the same name). Returns it.
    @discardableResult
    public static func save(name: String, tokens: [String: JSONValue], description: String? = nil) throws -> ThemePreset
    {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw ModelError.invalid("a preset needs a name") }
        guard !tokens.isEmpty else { throw ModelError.invalid("the theme has no tokens to save") }
        var id = slug(n)
        if id.isEmpty { id = "theme" }
        if builtIn.contains(where: { $0.id == id || $0.name.lowercased() == n.lowercased() }) { id = "my-" + id }
        let preset = ThemePreset(id: id, name: n, description: description, tokens: tokens)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try JSONFormat.pretty().encode(preset).write(to: userDir.appendingPathComponent("\(id).json"), options: .atomic)
        return preset
    }

    /// Deletes a user preset. Built-in presets cannot be deleted.
    public static func delete(_ id: String) throws {
        guard !builtIn.contains(where: { $0.id == id }) else {
            throw ModelError.invalid("built-in presets can't be deleted")
        }
        let url = userDir.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelError.invalid("no saved preset '\(id)'")
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Applying

    /// The project theme after applying `preset`: its tokens replace the matching ones; every other token
    /// (the user's custom extras like `$whisper` or `$piece`) is kept unchanged.
    public static func applying(_ preset: ThemePreset, to theme: [String: JSONValue]) -> [String: JSONValue] {
        theme.merging(preset.tokens) { _, new in new }
    }

    /// Whether the theme currently looks like `preset` (every preset token the theme has is equal, and bg/fg exist).
    public static func matches(_ preset: ThemePreset, _ theme: [String: JSONValue]) -> Bool {
        guard theme["bg"] != nil, theme["fg"] != nil else { return false }
        var shared = 0
        for (k, v) in preset.tokens {
            guard let cur = theme[k] else { continue }
            guard same(cur, v) else { return false }
            shared += 1
        }
        return shared >= 3
    }

    /// The built-in or user preset the theme matches, if any (user presets win, they are more specific).
    public static func current(_ theme: [String: JSONValue]) -> ThemePreset? {
        all().reversed().first { matches($0, theme) }
    }

    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.string, let y = b.string { return x.caseInsensitiveCompare(y) == .orderedSame }
        return a == b
    }

    static func slug(_ s: String) -> String {
        let lower = s.lowercased()
        var out = ""
        var dash = false
        for ch in lower {
            if ch.isLetter || ch.isNumber {
                out.append(ch); dash = false
            } else if !dash && !out.isEmpty {
                out.append("-"); dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
