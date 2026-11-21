import CryptoKit
import Foundation

/// The words of a voiceover with the time each is spoken, so sound and picture can land on a word instead of
/// on a guess. Made by speech-to-text (ElevenLabs Scribe on fal.ai, the user's key) and kept per file in
/// `.arclight/transcripts/`, so a file is only ever transcribed once.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
    }

    public var text: String
    public var language: String?
    public var words: [Word]
    public init(text: String, language: String? = nil, words: [Word]) {
        self.text = text; self.language = language; self.words = words
    }

    static let model = "fal-ai/elevenlabs/speech-to-text"

    /// A Scribe result (`words` with `type` word / spacing / audio_event) as a transcript of the spoken words.
    public static func parse(_ v: JSONValue) -> Transcript? {
        guard let list = v["words"]?.array else { return nil }
        let words = list.compactMap { w -> Word? in
            guard (w["type"]?.string ?? "word") == "word", let t = w["text"]?.string, let s = w["start"]?.double,
                let e = w["end"]?.double
            else { return nil }
            return Word(text: t.trimmingCharacters(in: .whitespaces), start: s, end: e)
        }
        return Transcript(text: v["text"]?.string ?? words.map(\.text).joined(separator: " "), language: v["language_code"]?.string, words: words)
    }

    /// Words grouped into lines: a new line after a pause of 0.45 s or sentence punctuation.
    public var lines: [[Word]] {
        var out: [[Word]] = []
        var cur: [Word] = []
        for w in words {
            if let last = cur.last, w.start - last.end >= 0.45 || ".!?…".contains(last.text.last ?? " ") {
                out.append(cur); cur = []
            }
            cur.append(w)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Words matching a word or phrase (case and punctuation ignored): the span each occurrence covers.
    public func find(_ phrase: String) -> [ClosedRange<Double>] {
        func norm(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        let want = phrase.split(separator: " ").map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !want.isEmpty, words.count >= want.count else { return [] }
        let have = words.map { norm($0.text) }
        var out: [ClosedRange<Double>] = []
        for i in 0...(have.count - want.count) where Array(have[i..<(i + want.count)]) == want {
            out.append(words[i].start...max(words[i].start, words[i + want.count - 1].end))
        }
        return out
    }

    // MARK: Cache

    static func cacheURL(for file: URL, store: ProjectStore) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let hash = SHA256.hash(data: Data("\(file.lastPathComponent)|\(stamp)|\(size)".utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        return ProjectLayout.hidden("transcripts", in: store.url)
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(hash).json")
    }

    public static func cached(_ file: URL, store: ProjectStore) -> Transcript? {
        (try? Data(contentsOf: cacheURL(for: file, store: store))).flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) }
    }

    /// The transcript of a sound file: from the cache, or made now (paid, a few cents a minute).
    public static func of(_ file: URL, language: String?, store: ProjectStore, provider: TranscriptProvider) async throws
        -> (transcript: Transcript, fresh: Bool)
    {
        if let t = cached(file, store: store) { return (t, false) }
        let data = try Data(contentsOf: file)
        guard data.count <= 24 * 1024 * 1024 else {
            throw ImageAIError.failed("the file is too big to transcribe (over 24 MB) — cut the part you need")
        }
        let ext = file.pathExtension.lowercased()
        let mime = ["mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac",
            "aif": "audio/aiff", "aiff": "audio/aiff", "caf": "audio/x-caf"][ext] ?? "application/octet-stream"
        let t = try await provider.transcribe(data, mime: mime, language: language)
        let u = cacheURL(for: file, store: store)
        try? JSONFile.write(t, to: u, encoder: JSONEncoder())
        ImageAI.log(store, op: "transcribe", model: model, prompt: String(t.text.prefix(120)), source: nil, asset: file.lastPathComponent)
        return (t, true)
    }
}

/// Something that turns speech into timed words (fal.ai; tests use a stand-in).
public protocol TranscriptProvider: Sendable {
    func transcribe(_ audio: Data, mime: String, language: String?) async throws -> Transcript
}

extension FalProvider: TranscriptProvider {
    public func transcribe(_ audio: Data, mime: String, language: String?) async throws -> Transcript {
        var p = self
        p.timeout = max(timeout, 300)
        var input: [String: JSONValue] = [
            "audio_url": .string("data:\(mime);base64,\(audio.base64EncodedString())"),
            "tag_audio_events": false, "diarize": false,
        ]
        if let language, !language.isEmpty { input["language_code"] = .string(language) }
        let result = try await p.result(Transcript.model, input)
        guard let t = Transcript.parse(result), !t.words.isEmpty else {
            throw ImageAIError.failed("no words were recognised in the audio")
        }
        return t
    }
}
