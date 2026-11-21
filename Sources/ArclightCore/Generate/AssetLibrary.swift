import Foundation

/// Free, ready-made assets from Poly Haven (polyhaven.com, all CC0: free for any use, no attribution needed):
/// ~500 3D models and ~900 tiling textures. Searching and importing need no key and cost nothing, so agents look
/// here before paying for a generated model (`model_generate`) or texture (`image_generate`).
///
/// Models come as glTF with separate buffers and textures; they are packed into one .glb (`GLTFPack`) so a
/// model is a single file in assets/, like a generated one.
public struct AssetLibrary: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case model, texture
        var apiType: String { self == .model ? "models" : "textures" }
    }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var name: String
        public var kind: Kind
        public var categories: [String]
        public var tags: [String]
        public var polycount: Int?
        /// Real-world size in centimetres (width, height, depth) where known.
        public var sizeCM: [Int]?

        public var line: String {
            var s = "\(id) — \(name)"
            if let p = polycount { s += ", \(p) polys" }
            if let d = sizeCM, d.count == 3 { s += ", \(d[0])×\(d[1])×\(d[2]) cm" }
            let words = Array(NSOrderedSet(array: categories + tags).array.compactMap { $0 as? String }.prefix(6))
            if !words.isEmpty { s += " [" + words.joined(separator: ", ") + "]" }
            return s
        }
    }

    let session: URLSession
    let api: URL
    public init(session: URLSession = .shared, api: URL = URL(string: "https://api.polyhaven.com")!) {
        self.session = session; self.api = api
    }

    // MARK: Search

    /// Items whose id, name, tags or categories match the words of `query`, best first.
    public func search(_ query: String, kind: Kind, limit: Int = 8) async throws -> [Item] {
        let all = try await list(kind)
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return Array(all.prefix(limit)) }
        func score(_ i: Item) -> Int {
            // Whole words only ("hand" must not find "chandelier"); a word may be a prefix ("pot" → "pots").
            let nameWords = Set(
                (i.name + " " + i.id).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let tagWords = Set(
                (i.tags + i.categories).flatMap { $0.lowercased().split { !$0.isLetter }.map(String.init) })
            var s = 0
            for w in words {
                let stem = w.count > 4 && w.hasSuffix("s") ? String(w.dropLast()) : w
                if nameWords.contains(where: { $0.hasPrefix(stem) }) { s += 3 }
                if tagWords.contains(where: { $0.hasPrefix(stem) }) { s += 2 }
            }
            return s
        }
        let scored: [(item: Item, score: Int)] = all.map { (item: $0, score: score($0)) }.filter { $0.score > 0 }
        let ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.item.id < b.item.id }
        return ranked.prefix(limit).map(\.item)
    }

    /// Every item of `kind` (one request; the catalog is small).
    public func list(_ kind: Kind) async throws -> [Item] {
        var c = URLComponents(url: api.appendingPathComponent("assets"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "type", value: kind.apiType)]
        let v = try await json(c.url!)
        guard let obj = v.object else { throw ImageAIError.failed("asset library: unexpected answer") }
        return obj.map { id, a in
            let dims = a["dimensions"]?.doubles
            return Item(
                id: id, name: a["name"]?.string ?? id, kind: kind,
                categories: a["categories"]?.array?.compactMap(\.string) ?? [],
                tags: a["tags"]?.array?.compactMap(\.string) ?? [],
                polycount: a["polycount"]?.double.map { Int($0) },
                sizeCM: dims.map { $0.map { Int(($0 / 10).rounded()) } })
        }.sorted { $0.id < $1.id }
    }

    // MARK: Import

    /// Downloads model `id` at `resolution` ("1k", "2k") as one .glb into assets/. Returns the file name.
    public func importModel(_ id: String, resolution: String = "1k", store: ProjectStore) async throws -> String {
        let files = try await json(api.appendingPathComponent("files").appendingPathComponent(id))
        guard let gltf = (files["gltf"]?[resolution] ?? files["gltf"]?["1k"])?["gltf"],
            let url = gltf["url"]?.string
        else { throw ImageAIError.failed("asset library: '\(id)' has no glTF model") }
        let json = try await download(url)
        // Only the files the glTF actually points at (buffers, the images its materials use).
        let include = gltf["include"]?.object ?? [:]
        var parts: [String: Data] = [:]
        for uri in GLTFPack.uris(json) {
            guard let u = include[uri]?["url"]?.string else {
                throw ImageAIError.failed("asset library: '\(id)' is missing \(uri)")
            }
            parts[uri] = try await download(u)
        }
        let glb = try GLTFPack.pack(json: json, files: parts)
        _ = try GLB.parse(glb)  // refuse anything the renderer can't read before it lands in assets/
        let name = try ModelAI.writeModel(glb, base: ImageAI.slug(id), store: store)
        ImageAI.log(store, op: "library", model: "polyhaven", prompt: id, source: nil, asset: name)
        return name
    }

    /// Downloads texture `id`'s colour map at `resolution` into assets/. Returns the file name.
    public func importTexture(_ id: String, resolution: String = "1k", store: ProjectStore) async throws -> String {
        let files = try await json(api.appendingPathComponent("files").appendingPathComponent(id))
        guard let diffuse = files["Diffuse"] ?? files["diff"],
            let url = (diffuse[resolution] ?? diffuse["1k"])?["jpg"]?["url"]?.string
        else { throw ImageAIError.failed("asset library: '\(id)' has no colour map") }
        let data = try await download(url)
        _ = try ImageData.decode(data)
        try FileManager.default.createDirectory(at: store.assetsURL, withIntermediateDirectories: true)
        let name = Naming.freeFile(ImageAI.slug(id), ext: "jpg", in: store.assetsURL)
        try data.write(to: store.assetsURL.appendingPathComponent(name), options: .atomic)
        ImageAI.log(store, op: "library", model: "polyhaven", prompt: id, source: nil, asset: name)
        return name
    }

    // MARK: HTTP

    func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        r.setValue("Arclight", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 60
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else {
            throw ImageAIError.failed(
                code == 404
                    ? "asset library: not found (check the id with library_search)" : "asset library: HTTP \(code)")
        }
        return data
    }

    func json(_ url: URL) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await get(url))
    }

    func download(_ s: String) async throws -> Data {
        guard let u = URL(string: s), u.scheme == "https" else { throw ImageAIError.failed("asset library: bad URL") }
        return try await get(u)
    }
}

/// Turns a .gltf and its side files (buffers, images) into one binary .glb: buffers are joined into the BIN chunk
/// and images are moved into it as buffer views.
public enum GLTFPack {
    /// Relative URIs the glTF needs: every buffer, and every image.
    static func uris(_ json: Data) -> [String] {
        guard let g = try? JSONDecoder().decode(JSONValue.self, from: json) else { return [] }
        let all = (g["buffers"]?.array ?? []) + (g["images"]?.array ?? [])
        var out: [String] = []
        for u in all.compactMap({ $0["uri"]?.string }) where !u.hasPrefix("data:") && !out.contains(u) {
            out.append(u.removingPercentEncoding ?? u)
        }
        return out
    }

    public static func pack(json: Data, files: [String: Data]) throws -> Data {
        guard var g = try JSONDecoder().decode(JSONValue.self, from: json).object else {
            throw MeshError.invalid("bad glTF JSON")
        }
        func file(_ uri: String) throws -> Data {
            if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","),
                let d = Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            {
                return d
            }
            guard let d = files[uri.removingPercentEncoding ?? uri] ?? files[uri] else {
                throw MeshError.invalid("missing \(uri)")
            }
            return d
        }
        var bin = Data()
        func align() { while bin.count % 4 != 0 { bin.append(0) } }
        // Buffers, one after another; remember where each starts.
        var starts: [Int] = []
        for b in g["buffers"]?.array ?? [] {
            align()
            starts.append(bin.count)
            bin.append(try file(b["uri"]?.string ?? ""))
        }
        var views = g["bufferViews"]?.array ?? []
        views = views.map { v in
            guard var o = v.object else { return v }
            let b = Int(o["buffer"]?.double ?? 0)
            o["byteOffset"] = .number(
                Double((o["byteOffset"]?.double.map { Int($0) } ?? 0) + (b < starts.count ? starts[b] : 0)))
            o["buffer"] = 0
            return .object(o)
        }
        // Images become buffer views.
        var images = g["images"]?.array ?? []
        for i in images.indices {
            guard var img = images[i].object, let uri = img["uri"]?.string else { continue }
            let d = try file(uri)
            align()
            views.append([
                "buffer": 0, "byteOffset": .number(Double(bin.count)), "byteLength": .number(Double(d.count)),
            ])
            bin.append(d)
            img["uri"] = nil
            img["bufferView"] = .number(Double(views.count - 1))
            img["mimeType"] = .string(uri.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg")
            images[i] = .object(img)
        }
        align()
        g["buffers"] = [["byteLength": .number(Double(bin.count))]]
        g["bufferViews"] = .array(views)
        if !images.isEmpty { g["images"] = .array(images) }
        var jsonChunk = try JSONEncoder().encode(JSONValue.object(g))
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + jsonChunk.count + 8 + bin.count)
        u32(jsonChunk.count); u32(0x4E4F_534A); out.append(jsonChunk)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        return out
    }
}
