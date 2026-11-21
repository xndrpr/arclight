import Foundation

/// Free sounds and music from the open web through Openverse (api.openverse.org, no key): Creative Commons sound
/// effects from Freesound and music from Jamendo, Wikimedia and others. Results are limited to licences that
/// allow commercial use and editing by default. Every import is credited in `assets/CREDITS.md`, since most
/// sounds are CC BY (free, but the creator must be named where the video is published).
public struct SoundLibrary: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Sound effects (Freesound).
        case sfx
        case music
        case any
    }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var creator: String?
        public var duration: Double?
        public var license: String
        public var licenseVersion: String?
        public var licenseURL: String?
        public var source: String
        public var landing: String?
        public var fileURL: String
        public var fileType: String?
        public var tags: [String]
        public var attribution: String?

        /// "CC0", "CC BY 4.0", …
        public var licenseName: String {
            let l = license.lowercased()
            if l == "cc0" { return "CC0" }
            if l == "pdm" { return "Public domain" }
            return "CC " + l.uppercased() + (licenseVersion.map { " \($0)" } ?? "")
        }

        /// Whether the creator must be named (everything but CC0 / public domain).
        public var needsCredit: Bool { !["cc0", "pdm"].contains(license.lowercased()) }

        public var line: String {
            var s = "\(id) — \(title)"
            if let d = duration { s += ", \(Format.number((d * 10).rounded() / 10))s" }
            if let c = creator { s += " by \(c)" }
            s += " (\(source), \(licenseName)\(needsCredit ? ", credit needed" : ""))"
            let t = tags.prefix(6)
            if !t.isEmpty { s += " [" + t.joined(separator: ", ") + "]" }
            return s
        }

        /// The credit line kept in CREDITS.md.
        public var credit: String {
            if let a = attribution, !a.isEmpty { return a + (landing.map { " (\($0))" } ?? "") }
            return "“\(title)”" + (creator.map { " by \($0)" } ?? "") + ", \(licenseName)" + (landing.map { " — \($0)" } ?? "")
        }
    }

    let session: URLSession
    let api: URL
    public init(session: URLSession = .shared, api: URL = URL(string: "https://api.openverse.org/v1")!) {
        self.session = session; self.api = api
    }

    // MARK: Search

    /// Sounds matching `query`, best first. `maxSeconds` / `minSeconds` filter by length; `commercial` keeps only
    /// licences that allow commercial use and changes (no NC / ND).
    public func search(
        _ query: String, kind: Kind = .any, limit: Int = 8, minSeconds: Double? = nil, maxSeconds: Double? = nil,
        commercial: Bool = true
    ) async throws -> [Item] {
        var c = URLComponents(url: api.appendingPathComponent("audio/"), resolvingAgainstBaseURL: false)!
        // 20 is the most Openverse allows without a key (more answers HTTP 401).
        var q = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page_size", value: "20")]
        if commercial { q.append(URLQueryItem(name: "license_type", value: "commercial,modification")) }
        switch kind {
        case .sfx: q.append(URLQueryItem(name: "source", value: "freesound"))
        case .music: q.append(URLQueryItem(name: "category", value: "music"))
        case .any: break
        }
        c.queryItems = q
        let v = try await json(c.url!)
        guard let results = v["results"]?.array else { throw ImageAIError.failed("sound search: unexpected answer") }
        var out: [Item] = []
        for r in results {
            guard let item = Self.item(r) else { continue }
            if let d = item.duration {
                if let m = maxSeconds, d > m { continue }
                if let m = minSeconds, d < m { continue }
            }
            out.append(item)
            if out.count >= limit { break }
        }
        return out
    }

    /// One Openverse result, with a file Core Audio can read (the main file or an alternative), else nil.
    static func item(_ r: JSONValue) -> Item? {
        guard let id = r["id"]?.string else { return nil }
        func playable(_ type: String?) -> Bool {
            guard let t = type?.lowercased() else { return true }  // unknown: checked after download
            return AudioFiles.readable.contains(t) || t == "mp32"  // Jamendo's "mp32" is an mp3
        }
        var file = r["url"]?.string
        var type = r["filetype"]?.string
        if !playable(type) {
            let alt = r["alt_files"]?.array?.first { playable($0["filetype"]?.string) && $0["url"]?.string != nil }
            file = alt?["url"]?.string
            type = alt?["filetype"]?.string
        }
        guard let file, file.hasPrefix("https://") || file.hasPrefix("http://") else { return nil }
        return Item(
            id: id, title: r["title"]?.string ?? id, creator: r["creator"]?.string,
            duration: r["duration"]?.double.map { $0 / 1000 }, license: r["license"]?.string ?? "unknown",
            licenseVersion: r["license_version"]?.string, licenseURL: r["license_url"]?.string,
            source: r["source"]?.string ?? r["provider"]?.string ?? "openverse",
            landing: r["foreign_landing_url"]?.string, fileURL: file, fileType: type,
            tags: r["tags"]?.array?.compactMap { $0["name"]?.string } ?? [],
            attribution: r["attribution"]?.string)
    }

    /// The details of one sound by id.
    public func get(_ id: String) async throws -> Item {
        let v = try await json(api.appendingPathComponent("audio").appendingPathComponent(id).appendingPathComponent(""))
        guard let item = Self.item(v) else { throw ImageAIError.failed("sound '\(id)' has no file Arclight can play") }
        return item
    }

    // MARK: Import

    /// Downloads sound `id` into assets/ and credits it. Returns the item and the file name.
    public func importSound(_ id: String, name: String? = nil, store: ProjectStore) async throws -> (
        item: Item, asset: String
    ) {
        let item = try await get(id)
        guard let u = URL(string: item.fileURL), u.scheme == "https" || u.scheme == "http" else {
            throw ImageAIError.failed("sound library: bad file URL")
        }
        let data = try await get(u)
        let asset = try AudioFiles.write(data, base: AudioFiles.slug(name ?? item.title), store: store)
        AudioFiles.credit(store, asset: asset, line: item.credit)
        ImageAI.log(store, op: "sound", model: "openverse/\(item.source)", prompt: item.title, source: item.landing, asset: asset)
        return (item, asset)
    }

    /// Downloads a search result to a temporary file and measures it (nothing is kept).
    public func measure(_ item: Item) async throws -> AudioDescriptors {
        guard let u = URL(string: item.fileURL), u.scheme == "https" || u.scheme == "http" else {
            throw ImageAIError.failed("sound library: bad file URL")
        }
        let data = try await get(u)
        guard data.count <= AudioFiles.maxBytes, let ext = AudioFiles.sniff(data) else {
            throw ImageAIError.failed("not a playable sound")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("measure-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try AudioDescriptors.measure(tmp)
    }

    // MARK: HTTP

    func get(_ url: URL) async throws -> Data {
        try await LibraryHTTP.get(url, session: session) { code in
            code == 404
                ? "sound library: not found (check the id with sound_search)"
                : code == 429 ? "sound library: too many searches — wait a minute" : "sound library: HTTP \(code)"
        }
    }

    func json(_ url: URL) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await get(url))
    }
}
