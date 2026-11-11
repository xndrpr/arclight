import Foundation

/// Checks names that become file or folder names (scene ids, template ids, asset names, symbol packs). A bad name is
/// rejected with a clear error, never rewritten, so a caller can't be surprised by where a file lands.
public enum SafeName {
    /// Longest accepted id or asset name, in characters.
    public static let maxLength = 128
    /// Longest accepted path component, in UTF-8 bytes (APFS allows 255; leave room for ".json").
    public static let maxComponentBytes = 240

    /// A new id from an agent or script: letters, digits, `-` and `_` only (1–128 characters).
    /// `what` names the argument in the message, e.g. "id" or "scene".
    @discardableResult
    public static func id(_ s: String, what: String = "id") throws -> String {
        guard !s.isEmpty else { throw ModelError.invalid("\(what) is empty") }
        guard s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw ModelError.invalid("\(what) may only contain letters, digits, - and _")
        }
        guard s.count <= maxLength else { throw ModelError.invalid("\(what) is longer than \(maxLength) characters") }
        return s
    }

    /// A new asset file name from an agent or script, e.g. `badge.png`: starts with a letter, digit, `-` or `_`, then
    /// letters, digits, `.`, `-`, `_` and spaces (1–128 characters). No folders.
    @discardableResult
    public static func fileName(_ s: String, what: String = "name") throws -> String {
        guard !s.isEmpty else { throw ModelError.invalid("\(what) is empty") }
        guard s.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._ -]*$", options: .regularExpression) != nil else {
            throw ModelError.invalid(
                "\(what) must be a plain file name (letters, digits, '.', '-', '_' and spaces; no folders): '\(s)'")
        }
        guard s.count <= maxLength else { throw ModelError.invalid("\(what) is longer than \(maxLength) characters") }
        return s
    }

    /// Any single path component that stays inside its folder: not empty, not `.`/`..`, no leading dot, no `/`,
    /// no control characters, at most 240 UTF-8 bytes. This is the store's last line of defence and accepts every
    /// name a file picker can produce (spaces, accents, any script), so existing projects keep working.
    @discardableResult
    public static func component(_ s: String, what: String = "name") throws -> String {
        guard !s.isEmpty else { throw ModelError.invalid("\(what) is empty") }
        guard !s.hasPrefix("."), !s.contains("/"),
            !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ModelError.invalid("\(what) '\(s)' is not a valid file name (no folders, no leading dot)")
        }
        guard s.utf8.count <= maxComponentBytes else {
            throw ModelError.invalid("\(what) is longer than \(maxComponentBytes) bytes")
        }
        return s
    }

    /// Whether `component` accepts `s`.
    public static func isComponent(_ s: String) -> Bool { (try? component(s)) != nil }
}
