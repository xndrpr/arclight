import CoreGraphics
import Foundation
import Vision

/// Looks at a reference thumbnail on this Mac (Vision + simple colour statistics) so a new thumbnail can follow its
/// *structure* — composition, hierarchy, colour mood — with the user's own photos, theme and words.
public enum ReferenceAnalyzer {
    public struct Region: Codable, Equatable, Sendable {
        /// [x, y, w, h] as fractions of the image (top-left origin).
        public var box: [Double]
        public var text: String?
        public var confidence: Double?
    }

    public struct Report: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// Dominant colours, most common first, as #RRGGBB with their share of the picture.
        public var palette: [String]
        public var shares: [Double]
        public var text: [Region]
        public var faces: [Region]
        /// Where the eye goes first (saliency), if found.
        public var focus: [Region]
        /// "light" or "dark" overall, and contrast between the darkest and lightest palette colours (WCAG ratio).
        public var tone: String
        public var contrast: Double
        /// Plain-language layout notes (thirds, sides, words, faces).
        public var layout: [String]
    }

    public static func analyze(_ img: CGImage) -> Report {
        let (palette, shares) = dominantColors(img, k: 5)
        let text = recognizeText(img)
        let faces = detectFaces(img)
        let focus = saliency(img)
        let lums = palette.compactMap { RGBA.parse(.string($0)) }.map(luminance)
        let avg = zip(lums, shares).map { $0 * $1 }.reduce(0, +)
        let contrast = (lums.max().map { hi in lums.min().map { lo in (hi + 0.05) / (lo + 0.05) } ?? 1 } ?? 1)
        var layout: [String] = []
        func side(_ r: Region) -> String {
            let cx = r.box[0] + r.box[2] / 2
            return cx < 0.38 ? "left" : cx > 0.62 ? "right" : "centre"
        }
        if let f = faces.max(by: { $0.box[2] * $0.box[3] < $1.box[2] * $1.box[3] }) {
            layout.append(
                "\(faces.count) face(s); the largest is on the \(side(f)), \(Int((f.box[3] * 100).rounded()))% of the height"
            )
        }
        let words = text.compactMap(\.text).joined(separator: " ").split(separator: " ").count
        if !text.isEmpty {
            let big = text.max { $0.box[3] < $1.box[3] }!
            layout.append(
                "\(words) word(s) of text; the biggest line (“\(big.text ?? "")”) is on the \(side(big)), \(Int((big.box[3] * 720).rounded())) px tall at 720p"
            )
        } else {
            layout.append("no text")
        }
        if let s = focus.first { layout.append("the eye lands \(side(s)) first") }
        if faces.contains(where: { side($0) == "left" }) && text.contains(where: { side($0) == "right" })
            || faces.contains(where: { side($0) == "right" }) && text.contains(where: { side($0) == "left" })
        {
            layout.append("split layout: face one side, words the other")
        }
        return Report(
            width: img.width, height: img.height, palette: palette, shares: shares, text: text, faces: faces,
            focus: focus, tone: avg > 0.45 ? "light" : "dark", contrast: contrast.rounded(places: 1), layout: layout)
    }

    public static func luminance(_ c: RGBA) -> Double {
        0.2126 * RGBA.toLinear(c.r) + 0.7152 * RGBA.toLinear(c.g) + 0.0722 * RGBA.toLinear(c.b)
    }

    /// k-means on a 64×36 copy, deterministic seeds spread over the luminance range.
    static func dominantColors(_ img: CGImage, k: Int) -> ([String], [Double]) {
        let w = 64, h = 36
        guard let ctx = ImageData.context(w, h) else { return ([], []) }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return ([], []) }
        var px: [SIMD3<Double>] = []
        for i in 0..<(w * h) {
            let o = i * 4
            guard d[o + 3] > 128 else { continue }
            px.append(SIMD3(Double(d[o]), Double(d[o + 1]), Double(d[o + 2])) / 255)
        }
        guard !px.isEmpty else { return ([], []) }
        func brightness(_ v: SIMD3<Double>) -> Double { v.x + v.y + v.z }
        let sorted = px.sorted { brightness($0) < brightness($1) }
        var centers: [SIMD3<Double>] = []
        for j in 0..<k {
            let idx: Int = min(sorted.count - 1, (2 * j + 1) * sorted.count / (2 * k))
            centers.append(sorted[idx])
        }
        var assign = [Int](repeating: 0, count: px.count)
        for _ in 0..<12 {
            for (i, p) in px.enumerated() {
                var best = 0, bd = Double.infinity
                for (j, c) in centers.enumerated() {
                    let dd = simd_length_squared(p - c)
                    if dd < bd { bd = dd; best = j }
                }
                assign[i] = best
            }
            for j in 0..<k {
                let members = px.indices.filter { assign[$0] == j }
                if !members.isEmpty { centers[j] = members.map { px[$0] }.reduce(.zero, +) / Double(members.count) }
            }
        }
        var counts = [Int](repeating: 0, count: k)
        for a in assign { counts[a] += 1 }
        let order = (0..<k).filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        let hex = order.map { j -> String in
            let c = centers[j]
            return String(format: "#%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
        }
        return (hex, order.map { (Double(counts[$0]) / Double(px.count)).rounded(places: 2) })
    }

    /// Vision's normalised (bottom-left origin) box → top-left fractions, rounded.
    static func box(_ r: CGRect) -> [Double] {
        [r.minX, 1 - r.maxY, r.width, r.height].map { Double($0).rounded(places: 3) }
    }

    static func recognizeText(_ img: CGImage) -> [Region] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return Region(
                box: box(o.boundingBox), text: c.string, confidence: Double(c.confidence).rounded(places: 2))
        }
    }

    static func detectFaces(_ img: CGImage) -> [Region] {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).map {
            Region(box: box($0.boundingBox), text: nil, confidence: Double($0.confidence))
        }
    }

    static func saliency(_ img: CGImage) -> [Region] {
        let req = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results?.first?.salientObjects ?? []).map {
            Region(box: box($0.boundingBox), text: nil, confidence: Double($0.confidence))
        }
    }

    /// The public thumbnail of a YouTube video (no API key): `maxresdefault.jpg`, falling back to `hqdefault.jpg`.
    public static func youtubeID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return t }
        guard let u = URLComponents(string: t), let host = u.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") { return u.path.split(separator: "/").first.map(String.init) }
        guard host.contains("youtube.com") else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = u.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), i + 1 < parts.count {
            return parts[i + 1]
        }
        return nil
    }

    public static func fetchYouTubeThumbnail(_ id: String, session: URLSession = .shared) async throws -> Data {
        for name in ["maxresdefault.jpg", "hqdefault.jpg"] {
            let url = URL(string: "https://img.youtube.com/vi/\(id)/\(name)")!
            let (data, resp) = try await session.data(from: url)
            if (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 2000 { return data }
        }
        throw ImageAIError.failed("couldn't fetch the thumbnail of video \(id)")
    }
}
