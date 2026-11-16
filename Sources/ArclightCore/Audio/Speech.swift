import Foundation

/// Voiceover made on the device with the system voices (`/usr/bin/say`): free, offline, many languages. Good for
/// drafts and timing; for a natural, expressive read use `AudioAI` (ElevenLabs through fal.ai).
public enum Speech {
    public struct Voice: Equatable, Sendable {
        public var name: String
        /// "en_US", "ru_RU", …
        public var language: String
    }

    /// Joke and effect voices that make poor voiceovers.
    static let novelty: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester", "Organ",
        "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Fred", "Junior", "Ralph", "Kathy",
    ]

    /// Lines of `say -v '?'`: "Name   xx_YY    # sample".
    static func parse(_ listing: String) -> [Voice] {
        listing.split(separator: "\n").compactMap { line in
            guard let hash = line.range(of: "#") else { return nil }
            let head = line[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let sp = head.range(of: " ", options: .backwards) else { return nil }
            let lang = head[sp.upperBound...].trimmingCharacters(in: .whitespaces)
            let name = head[..<sp.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, lang.count >= 2 else { return nil }
            return Voice(name: name, language: lang)
        }
    }

    public static func voices() -> [Voice] {
        guard let out = try? run(["-v", "?"]) else { return [] }
        return parse(out).filter { !novelty.contains($0.name) }
    }

    /// The voice to use: `name` if given (case-insensitive, also matching "Eddy" for "Eddy (English (US))"),
    /// else a good one for the text's language.
    public static func pick(_ name: String?, text: String, from voices: [Voice]) -> Voice? {
        if let name, !name.isEmpty {
            let n = name.lowercased()
            return voices.first { $0.name.lowercased() == n }
                ?? voices.first { $0.name.lowercased().hasPrefix(n + " (") || $0.name.lowercased().hasPrefix(n) }
        }
        let lang = language(of: text)
        let preferred = ["ru": ["Milena", "Yuri"], "en": ["Samantha", "Alex", "Daniel"], "de": ["Anna"], "fr": ["Thomas"]]
        for p in preferred[lang] ?? [] { if let v = voices.first(where: { $0.name == p }) { return v } }
        return voices.first { $0.language.hasPrefix(lang) }
    }

    /// A rough language guess from the script: Cyrillic → ru, else en.
    static func language(of text: String) -> String {
        let cyr = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let lat = text.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 122) }.count
        return cyr > lat ? "ru" : "en"
    }

    /// Speaks `text` into assets/ as a WAV. `rate` in words per minute (system default about 175).
    public static func write(
        _ text: String, voice: String?, rate: Double?, name: String?, store: ProjectStore
    ) throws -> (asset: String, voice: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ImageAIError.failed("nothing to say") }
        guard clean.count <= 5000 else { throw ImageAIError.failed("the text is too long (5000 characters at most)") }
        let all = voices()
        guard let v = pick(voice, text: clean, from: all) else {
            throw ImageAIError.failed(
                voice.map { "no system voice '\($0)' — voice_generate {list:true} shows them" }
                    ?? "no system voice for this language (add one in System Settings ▸ Accessibility ▸ Spoken Content)")
        }
        let url = try AudioFiles.freeName(AudioFiles.slug(name ?? "voice " + clean), store: store)
        var args = ["-v", v.name, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@48000"]
        if let rate { args += ["-r", String(Int(min(400, max(80, rate))))] }
        // The text goes through a file so nothing in it is read as an option.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-say-\(UUID().uuidString).txt")
        try clean.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try run(args + ["-f", tmp.path])
        guard SceneAudio.info(url) != nil else {
            try? FileManager.default.removeItem(at: url)
            throw ImageAIError.failed("the system voice made no sound")
        }
        ImageAI.log(store, op: "voice", model: "system:\(v.name)", prompt: clean, source: nil, asset: url.lastPathComponent)
        return (url.lastPathComponent, v.name)
    }

    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = args
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe; p.standardError = err
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ImageAIError.failed("system voice failed: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
