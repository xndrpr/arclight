import Foundation

/// Ids and file names made from free text, and free variants of a taken name.
public enum Naming {
    /// Lowercase ASCII letters and digits.
    public static let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")

    /// `s` lowercased, with every run of characters outside `kept` turned into one "-" ("Hello, World!" →
    /// "hello-world"). At most `maxWords` words and `maxLength` characters; `fallback` when nothing is left.
    public static func slug(
        _ s: String, keeping kept: CharacterSet = .alphanumerics, maxWords: Int = .max, maxLength: Int = .max,
        fallback: String = ""
    ) -> String {
        let words = s.lowercased().components(separatedBy: kept.inverted).filter { !$0.isEmpty }
        let joined = words.prefix(maxWords).joined(separator: "-")
        return joined.isEmpty ? fallback : String(joined.prefix(maxLength))
    }

    /// `s` in plain ASCII Latin letters ("Привет, мир" → "Privet, mir"), so file names stay portable.
    public static func latin(_ s: String) -> String {
        let latin =
            s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return String(latin.unicodeScalars.filter(\.isASCII).map(Character.init))
    }

    /// `base` if it is free, else the first free one of `base-2`, `base-3`, …
    public static func unique(_ base: String, taken: (String) -> Bool) -> String {
        if !taken(base) { return base }
        var k = 2
        while taken("\(base)-\(k)") { k += 1 }
        return "\(base)-\(k)"
    }

    /// `base` if no id in `ids` has it, else the first free one of `base-2`, `base-3`, …
    public static func unique(_ base: String, in ids: Set<String>) -> String {
        unique(base) { ids.contains($0) }
    }

    /// A file name `base.ext` not taken in `folder` (`base-2.ext`, … otherwise).
    public static func freeFile(_ base: String, ext: String, in folder: URL) -> String {
        unique(base) { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0).\(ext)").path) }
            + ".\(ext)"
    }
}
