import CoreGraphics
import Foundation

extension Symbols {
    /// Outline of a symbol for drawing small previews (e.g. the editor's symbol browser): all fills combined,
    /// in CoreGraphics coordinates (y up, base centred at the origin). Nil for unknown ids.
    public static func previewPath(_ id: String, project: URL? = nil) -> CGPath? {
        guard let sprite = sprite(id, project: project), !sprite.fills.isEmpty else { return nil }
        let out = CGMutablePath()
        for f in sprite.fills { out.addPath(f) }
        return out
    }

    /// Whether the symbol's fills use the even-odd rule (holes), for drawing `previewPath`.
    public static func previewUsesEvenOdd(_ id: String, project: URL? = nil) -> Bool {
        sprite(id, project: project)?.evenOdd ?? false
    }
}
