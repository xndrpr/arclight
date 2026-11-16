import Foundation

/// AI-generated audio through fal.ai (the user's key, paid): sound effects and music from a description, and
/// voiceover from text (ElevenLabs). Results land in assets/ like any other sound.
public enum AudioAI {
    public enum Kind: String, CaseIterable, Sendable {
        case sfx, music, voice
    }

    public struct Request: Sendable {
        public var kind: Kind
        /// What it should sound like (sfx, music) or the words to say (voice).
        public var prompt: String
        /// Seconds (sfx 0.5–30, music 3–600); nil lets the model decide.
        public var duration: Double?
        /// Music: no singing.
        public var instrumental = true
        /// Sfx: made to loop seamlessly.
        public var loop = false
        /// Voice name (ElevenLabs: Rachel, Aria, Roger, Sarah, Laura, Charlie, George, River, Liam, Charlotte, …).
        public var voice: String?
        /// Voice speed 0.7–1.2.
        public var speed: Double?
        /// Voice language, ISO 639-1 ("ru", "en").
        public var language: String?
        /// A fal model id for this call (default: the catalog's first for the kind).
        public var model: String?
        public init(kind: Kind, prompt: String) { self.kind = kind; self.prompt = prompt }
    }

    public struct Result: Sendable {
        public var asset: String
        public var model: String
        public var duration: Double
        /// Models that rejected the request before one worked.
        public var failed: [String]
    }

    /// Generates and writes into assets/.
    public static func generate(_ r: Request, name: String?, store: ProjectStore, provider: AudioProvider) async throws
        -> Result
    {
        let prompt = r.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ImageAIError.failed(r.kind == .voice ? "no text to say" : "describe the sound") }
        var req = r
        req.prompt = prompt
        let made = try await provider.audio(req)
        let base = AudioFiles.slug(name ?? ((r.kind == .voice ? "voice " : "") + prompt))
        let asset = try AudioFiles.write(made.data, base: base, store: store)
        ImageAI.log(store, op: r.kind == .voice ? "voice" : "sound", model: made.model, prompt: prompt, source: nil, asset: asset)
        let d = SceneAudio.info(store.assetsURL.appendingPathComponent(asset))?.duration ?? 0
        return Result(asset: asset, model: made.model, duration: d, failed: made.failed)
    }
}

public struct GeneratedAudio: Sendable {
    public var data: Data
    public var model: String
    public var failed: [String] = []
    public init(data: Data, model: String, failed: [String] = []) {
        self.data = data; self.model = model; self.failed = failed
    }
}

/// Something that makes audio from a request (fal.ai; tests use a stand-in).
public protocol AudioProvider: Sendable {
    func audio(_ r: AudioAI.Request) async throws -> GeneratedAudio
}

/// The fal audio models Arclight knows how to call, in the order tried.
public enum AudioCatalog {
    public struct Entry: Sendable {
        public var id: String
        public var kind: AudioAI.Kind
        public var label: String
        public var note: String
    }

    public static let all: [Entry] = [
        Entry(
            id: "elevenlabs/sound-effects/v3", kind: .sfx, label: "ElevenLabs Sound Effects v3",
            note: "any sound effect from a description, 0.5–30 s, can loop"),
        Entry(
            id: "fal-ai/elevenlabs/sound-effects/v2", kind: .sfx, label: "ElevenLabs Sound Effects v2",
            note: "older, 0.5–22 s (fallback)"),
        Entry(
            id: "fal-ai/elevenlabs/music", kind: .music, label: "ElevenLabs Music",
            note: "songs or instrumentals, 3 s – 10 min"),
        Entry(
            id: "fal-ai/stable-audio-25/text-to-audio", kind: .music, label: "Stable Audio 2.5",
            note: "instrumental music and ambience, up to ~3 min (fallback)"),
        Entry(
            id: "fal-ai/elevenlabs/tts/multilingual-v2", kind: .voice, label: "ElevenLabs Multilingual v2",
            note: "natural voiceover in 29 languages"),
    ]

    public static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }
    public static func models(_ kind: AudioAI.Kind) -> [Entry] { all.filter { $0.kind == kind } }

    public static var summary: String {
        AudioAI.Kind.allCases.map { k in
            "\(k.rawValue): " + models(k).map { "\($0.id) (\($0.label) — \($0.note))" }.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    /// The request body for a model, shaped by its family.
    static func input(model: String, _ r: AudioAI.Request) -> [String: JSONValue] {
        var b: [String: JSONValue] = [:]
        if model.contains("sound-effects") {
            b["text"] = .string(r.prompt)
            if let d = r.duration {
                b["duration_seconds"] = .number(min(model.hasSuffix("/v2") ? 22 : 30, max(0.5, d)))
            }
            if r.loop { b["loop"] = true }
            b["output_format"] = "mp3_44100_128"
        } else if model.contains("elevenlabs/music") {
            b["prompt"] = .string(r.prompt)
            if let d = r.duration { b["music_length_ms"] = .number((min(600, max(3, d)) * 1000).rounded()) }
            b["force_instrumental"] = .bool(r.instrumental)
        } else if model.contains("stable-audio") {
            b["prompt"] = .string(r.prompt + (r.instrumental ? ", instrumental" : ""))
            b["seconds_total"] = .number((min(190, max(1, r.duration ?? 30))).rounded())
        } else if model.contains("tts") {
            b["text"] = .string(r.prompt)
            if let v = r.voice, !v.isEmpty { b["voice"] = .string(v) }
            if let s = r.speed { b["speed"] = .number(min(1.2, max(0.7, s))) }
            if let l = r.language, !l.isEmpty { b["language_code"] = .string(l) }
        } else {
            b["prompt"] = .string(r.prompt)
            if let d = r.duration { b["duration"] = .number(d) }
        }
        return b
    }

    /// The audio file a result links to: `audio.url`, `audio` as a string, or `audio_file.url`.
    static func audioURL(in v: JSONValue) -> String? {
        v["audio"]?["url"]?.string ?? v["audio"]?.string ?? v["audio_file"]?["url"]?.string
            ?? v["audio_url"]?["url"]?.string ?? v["audio_url"]?.string
    }
}

extension FalProvider: AudioProvider {
    /// Tries the request's model (or the catalog's models for the kind, in order) until one works; a model that
    /// rejects the request (a 4xx other than a bad key or rate limit) moves on to the next.
    public func audio(_ r: AudioAI.Request) async throws -> GeneratedAudio {
        var p = self
        p.timeout = max(timeout, r.kind == .music ? 600 : 240)
        let queue = r.model.map { [$0] } ?? AudioCatalog.models(r.kind).map(\.id)
        var failed: [String] = []
        var lastError: Error?
        for model in queue {
            do {
                let result = try await p.result(model, AudioCatalog.input(model: model, r))
                guard let url = AudioCatalog.audioURL(in: result) else {
                    throw ImageAIError.failed("fal.ai: no audio in the result")
                }
                return GeneratedAudio(data: try await p.download(url), model: model, failed: failed)
            } catch let e as ImageAIError {
                guard case .http(let code, let body) = e, Self.isRequestError(code) else { throw e }
                failed.append("\(model): HTTP \(code) \(Self.reason(body))")
                lastError = e
            }
        }
        throw lastError ?? ImageAIError.failed("fal.ai: no audio model to try")
    }
}
