import CoreText
import Foundation

/// Compact, token-cheap text view of a scene: one line per node, children indented.
/// Constant props are shown inline; animated props are listed after `~` (k3 = 3 keyframes, expr = expression).
public enum Outline {
    public static func scene(_ s: Scene, project: Project) -> String {
        let (w, h) = project.size(for: s)
        var out =
            "scene \(s.id)\(s.name.map { " \"\($0)\"" } ?? "")  \(Format.number(s.duration))s  \(w)x\(h)@\(Format.number(s.fps ?? project.fps))"
        if let bg = s.background { out += "  bg=\(short(bg))" }
        out += "  rev \(s.rev)  \(s.nodes.count) nodes\n"
        if let ms = s.markers, !ms.isEmpty {
            out += "markers: " + ms.map { "\($0.name)@\(Format.number($0.t))" }.joined(separator: ", ") + "\n"
        }
        if let a = s.audio {
            out +=
                "audio: \(a.src) at \(Format.number(a.offset ?? 0))s"
                + (a.gain.map { " gain \(Format.number($0))" } ?? "") + (a.mute == true ? " (muted)" : "") + "\n"
        }
        for (k, p) in [("camera", s.camera), ("fog", s.fog), ("post", s.post)] {
            guard let p else { continue }
            out += "\(k): " + (p.isAnimated ? "(animated, \(p.keyCount) keys) " : "") + compact(p.json) + "\n"
        }
        let ids = Set(s.nodes.map(\.id))
        var children: [String: [Node]] = [:]
        for n in s.nodes { children[n.parent.flatMap { ids.contains($0) ? $0 : nil } ?? "", default: []].append(n) }
        func walk(_ parent: String, _ depth: Int) {
            for n in children[parent] ?? [] {
                out += String(repeating: "  ", count: depth) + node(n) + "\n"
                walk(n.id, depth + 1)
            }
        }
        walk("", 0)
        return out
    }

    public static func node(_ n: Node) -> String {
        var parts = [n.id, n.type]
        if let s = n.start ?? n.end.map({ _ in 0 }) {
            parts.append("[\(Format.number(s))-\(n.end.map(Format.number) ?? "end")]")
        }
        var animated: [String] = []
        for k in n.props.keys.sorted() {
            switch n.props[k]! {
            case .value(let v): parts.append("\(k)=\(short(.value(v)))")
            case .keys(let ks): animated.append("\(k)(k\(ks.count))")
            case .expr: animated.append("\(k)(expr)")
            }
        }
        if !animated.isEmpty { parts.append("~ " + animated.joined(separator: " ")) }
        return parts.joined(separator: " ")
    }

    static func short(_ p: Prop) -> String {
        guard case .value(let v) = p else { return "~" }
        let s: String
        switch v {
        case .string(let x): s = x.contains(" ") || x.isEmpty ? "\"\(x)\"" : x
        case .number(let d): s = Format.number(d)
        default: s = (try? String(data: JSONFormat.compact().encode(v), encoding: .utf8)) ?? "?"
        }
        return s.count > 48 ? String(s.prefix(45)) + "…" : s
    }

    static func compact(_ v: JSONValue) -> String {
        let s = (try? String(data: JSONFormat.compact().encode(v), encoding: .utf8)) ?? "?"
        return s.count > 160 ? String(s.prefix(157)) + "…" : s
    }
}

public enum Fonts {
    public static func exists(_ name: String) -> Bool { TextLayout.fontExists(name) }

    /// PostScript names of installed fonts matching `query`, optionally only those with Cyrillic.
    public static func list(query: String?, cyrillic: Bool) -> [String] {
        let names = (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
        let q = query?.lowercased()
        return names.filter { name in
            if let q, !q.isEmpty, !name.lowercased().contains(q) { return false }
            if name.hasPrefix(".") { return false }
            if cyrillic {
                let f = CTFontCreateWithName(name as CFString, 12, nil)
                let set = CTFontCopyCharacterSet(f) as CharacterSet
                return set.contains(Unicode.Scalar(0x0416)!)  // Ж
            }
            return true
        }.sorted()
    }
}
