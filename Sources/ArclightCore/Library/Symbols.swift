import CoreGraphics
import Foundation

/// A vector silhouette for repeater items: filled shapes plus an optional highlight
/// ("rim") stroked along the top edges, lit in proportion to the instance's `lit`.
/// Coordinates are CoreGraphics (y up), base centred at the origin.
struct VectorSprite {
    var fills: [CGPath]
    var rim: CGPath?
    /// Rim stroke width in the same units as the paths.
    var rimWidth: CGFloat
    var evenOdd: Bool = false

    var bounds: CGRect {
        fills.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
    }
}

/// Symbol library used by repeater items: `{"symbol": "basic/person"}`.
///
/// Packs come from three places (later wins on id clashes):
/// 1. built in (`basic`, `chess`),
/// 2. the user library `~/Library/Application Support/Arclight/library/symbols/*.json`,
/// 3. the project's `symbols/*.json`.
///
/// Pack file format:
/// `{"pack":"brand","symbols":[{"id":"logo","name":"Logo","path":"M…","rim":"M…","fillRule":"evenodd"}]}`
/// Paths are SVG path data (y down); the bottom of a symbol's bounds stands on the floor.
public enum Symbols {
    public struct Info: Equatable, Hashable, Sendable {
        public let id: String  // "pack/name"
        public let name: String
        public let pack: String
        public let hasRim: Bool
    }

    struct Def {
        let info: Info
        let make: () -> VectorSprite?
    }

    /// Item JSON for a single SVG-defined symbol, as accepted by `SVGPath.sprite`.
    static func svg(
        _ pack: String, _ id: String, _ name: String, _ path: String, rim: String? = nil, evenOdd: Bool = false
    ) -> Def {
        var item: [String: JSONValue] = ["path": .string(path)]
        if let rim { item["rim"] = .string(rim) }
        if evenOdd { item["fillRule"] = "evenodd" }
        return Def(info: Info(id: "\(pack)/\(id)", name: name, pack: pack, hasRim: rim != nil)) {
            try? SVGPath.sprite(item)
        }
    }

    static func star(points: Int = 5, outer: Double = 50, inner: Double = 21) -> String {
        var d = ""
        for k in 0..<(points * 2) {
            let r = k % 2 == 0 ? outer : inner
            let a = -Double.pi / 2 + Double(k) * Double.pi / Double(points)
            d += String(format: "%@%.2f %.2f ", k == 0 ? "M" : "L", r * cos(a), r * sin(a) - outer)
        }
        return d + "Z"
    }

    static let person =
        "M0 -100 A11 11 0 1 1 0 -78 A11 11 0 1 1 0 -100 Z M-18 -73 Q0 -79 18 -73 L23 -40 L15 -38 L13 0 L3 0 L0 -30 L-3 0 L-13 0 L-15 -38 L-23 -40 Z"
    static let personRim = "M-8 -98 A11 11 0 0 1 8 -98 M-16 -73 Q0 -79 16 -73"

    static let builtIn: [Def] = {
        var defs: [Def] = [
            svg("basic", "person", "Person", person, rim: personRim),
            svg(
                "basic", "people", "People",
                "M-28 -88 A9 9 0 1 1 -28 -70 A9 9 0 1 1 -28 -88 Z M-43 -66 Q-28 -71 -13 -66 L-10 -38 L-16 -36 L-17 -4 L-25 -4 L-28 -28 L-31 -4 L-39 -4 L-40 -36 L-46 -38 Z "
                    + "M28 -88 A9 9 0 1 1 28 -70 A9 9 0 1 1 28 -88 Z M13 -66 Q28 -71 43 -66 L46 -38 L40 -36 L39 -4 L31 -4 L28 -28 L25 -4 L17 -4 L16 -36 L10 -38 Z "
                    + person,
                rim: personRim),
            svg(
                "basic", "dot", "Dot", "M0 -100 A50 50 0 1 1 0 0 A50 50 0 1 1 0 -100 Z",
                rim: "M-30 -90 A50 50 0 0 1 30 -90"),
            svg("basic", "star", "Star", star()),
            svg(
                "basic", "heart", "Heart",
                "M0 0 C-10 -12 -50 -38 -50 -66 C-50 -86 -34 -98 -20 -98 C-10 -98 -3 -92 0 -84 C3 -92 10 -98 20 -98 C34 -98 50 -86 50 -66 C50 -38 10 -12 0 0 Z"
            ),
            svg(
                "basic", "pin", "Map pin",
                "M0 0 C-6 -14 -30 -40 -30 -62 A30 30 0 1 1 30 -62 C30 -40 6 -14 0 0 Z M0 -74 A12 12 0 1 0 0.01 -74 Z",
                evenOdd: true),
            svg(
                "basic", "arrow-up", "Arrow up", "M0 -100 L40 -55 L14 -55 L14 0 L-14 0 L-14 -55 L-40 -55 Z",
                rim: "M-36 -57 L0 -97 L36 -57"),
            svg(
                "basic", "house", "House", "M-40 0 L-40 -55 L0 -95 L40 -55 L40 0 L12 0 L12 -30 L-12 -30 L-12 0 Z",
                rim: "M-38 -56 L0 -92 L38 -56"),
            svg(
                "basic", "building", "Building",
                "M-30 0 L-30 -100 L30 -100 L30 0 Z M-20 -88 L-8 -88 L-8 -76 L-20 -76 Z M8 -88 L20 -88 L20 -76 L8 -76 Z M-20 -64 L-8 -64 L-8 -52 L-20 -52 Z M8 -64 L20 -64 L20 -52 L8 -52 Z M-20 -40 L-8 -40 L-8 -28 L-20 -28 Z M8 -40 L20 -40 L20 -28 L8 -28 Z",
                rim: "M-30 -100 L30 -100", evenOdd: true),
            svg(
                "basic", "coin", "Coin",
                "M0 -100 A50 50 0 1 1 0 0 A50 50 0 1 1 0 -100 Z M0 -88 A38 38 0 1 0 0.01 -88 Z",
                rim: "M-30 -90 A50 50 0 0 1 30 -90", evenOdd: true),
            svg("basic", "bar", "Bar", "M-20 0 L-20 -100 L20 -100 L20 0 Z", rim: "M-20 -100 L20 -100"),
            svg("basic", "check", "Check", "M-45 -50 L-30 -65 L-10 -45 L32 -90 L47 -75 L-10 -15 Z"),
        ]
        for name in ChessPieces.names {
            defs.append(
                Def(info: Info(id: "chess/\(name)", name: name.capitalized, pack: "chess", hasRim: true)) {
                    ChessPieces.make(name)
                })
        }
        return defs
    }()

    // MARK: Lookup

    private static var cache: [String: (stamp: Date?, defs: [Def])] = [:]
    private static let lock = NSLock()

    static var userLibrary: URL {
        AppPaths.library("symbols")
    }

    /// Symbols from `*.json` packs in a folder (cached until the folder changes).
    static func packs(in dir: URL) -> [Def] {
        let fm = FileManager.default
        let stamp = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate]) as? Date
        lock.lock(); defer { lock.unlock() }
        if let c = cache[dir.path], c.stamp == stamp { return c.defs }
        var defs: [Def] = []
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let j = JSONFile.read(JSONValue.self, from: f) else { continue }
            let pack = j["pack"]?.string ?? f.deletingPathExtension().lastPathComponent
            for s in j["symbols"]?.array ?? [] {
                guard let o = s.object, let id = o["id"]?.string, o["path"]?.string != nil else { continue }
                defs.append(
                    Def(
                        info: Info(
                            id: "\(pack)/\(id)", name: o["name"]?.string ?? id, pack: pack, hasRim: o["rim"] != nil)
                    ) {
                        try? SVGPath.sprite(o)
                    })
            }
        }
        cache[dir.path] = (stamp, defs)
        return defs
    }

    static func defs(project: URL?) -> [Def] {
        var out = builtIn + packs(in: userLibrary)
        if let project { out += packs(in: project.appendingPathComponent("symbols")) }
        return out
    }

    /// All available symbols (built-in, user library, project).
    public static func all(project: URL? = nil) -> [Info] {
        var seen = Set<String>()
        return defs(project: project).reversed().filter { seen.insert($0.info.id).inserted }.reversed().map(\.info)
    }

    public static func exists(_ id: String, project: URL? = nil) -> Bool {
        defs(project: project).contains { $0.info.id == id }
    }

    static func sprite(_ id: String, project: URL?) -> VectorSprite? {
        defs(project: project).last { $0.info.id == id }?.make()
    }
}
