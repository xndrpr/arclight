import CoreGraphics
import Foundation

/// Where the floating AI panel sits over the viewport, and how big it is. Pure geometry (tested); the view is
/// `FloatingAIPanel`.
///
/// The panel is anchored to one corner of its container (the whole window area below the top bar) and keeps its distance
/// from that corner when the window resizes, so a panel parked bottom-left stays bottom-left. Whatever happens,
/// `frame(in:)` keeps it fully inside the container, shrinking it if the container is smaller than the panel.
struct AIPanelLayout: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
        var leading: Bool { self == .topLeading || self == .bottomLeading }
        var top: Bool { self == .topLeading || self == .topTrailing }
        init(leading: Bool, top: Bool) {
            self = top ? (leading ? .topLeading : .topTrailing) : (leading ? .bottomLeading : .bottomTrailing)
        }
    }

    var corner: Corner = .topTrailing
    /// Distance from the anchored corner (inside the margin), horizontally and vertically.
    var dx: Double = 0
    var dy: Double = 0
    var width: Double = AIPanelLayout.defaultSize.width
    var height: Double = AIPanelLayout.defaultSize.height
    /// Only the header is shown.
    var collapsed = false

    static let defaultSize = CGSize(width: 340, height: 560)
    static let minSize = CGSize(width: 280, height: 220)
    static let maxSize = CGSize(width: 640, height: 1600)
    /// Gap between the panel and the container's edges.
    static let margin: Double = 10
    /// Top gap below the top bar. The panel can float anywhere in the window below it, over any panel.
    static let topMargin: Double = 10
    /// Released within this distance of a corner (on both axes), the panel snaps into it.
    static let snap: Double = 40
    static let headerHeight: Double = 40
    /// Below this container size the panel stops floating and covers the viewport like a sheet.
    static let sheetBelow = CGSize(width: 400, height: 300)
    static let sheetInset: Double = 6

    // MARK: Geometry

    func isSheet(in c: CGSize) -> Bool { c.width < Self.sheetBelow.width || c.height < Self.sheetBelow.height }

    /// Panel size that fits `c` (header height when collapsed).
    func size(in c: CGSize) -> CGSize {
        let m = Self.margin
        let availW = max(0, Double(c.width) - 2 * m), availH = max(0, Double(c.height) - m - Self.topMargin)
        let w = min(clamp(width, Double(Self.minSize.width), Double(Self.maxSize.width)), availW)
        let h =
            collapsed
            ? min(Self.headerHeight, availH)
            : min(clamp(height, Double(Self.minSize.height), Double(Self.maxSize.height)), availH)
        return CGSize(width: w, height: h)
    }

    /// The panel's frame in container coordinates (top-left origin), always fully inside `c`.
    func frame(in c: CGSize) -> CGRect {
        if isSheet(in: c) {
            let r = CGRect(origin: .zero, size: c).insetBy(dx: Self.sheetInset, dy: Self.sheetInset)
            return collapsed
                ? CGRect(x: r.minX, y: r.minY, width: r.width, height: min(Self.headerHeight, r.height)) : r
        }
        let s = size(in: c), m = Self.margin
        let x = corner.leading ? m + dx : Double(c.width) - m - dx - Double(s.width)
        let y = corner.top ? Self.topMargin + dy : Double(c.height) - m - dy - Double(s.height)
        return Self.clamped(CGRect(x: x, y: y, width: Double(s.width), height: Double(s.height)), in: c)
    }

    /// Moves `r` so it lies inside `c` (keeping its size; if it is bigger than `c` it sits at the margin).
    static func clamped(_ r: CGRect, in c: CGSize) -> CGRect {
        let m = CGFloat(margin), top = CGFloat(topMargin)
        let x = max(m, min(r.minX, c.width - m - r.width))
        let y = max(top, min(r.minY, c.height - m - r.height))
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// Re-anchors to the corner nearest the frame's centre after a drag. Near a corner (both distances under
    /// `snap`) it snaps into that corner.
    func settled(_ f: CGRect, in c: CGSize, snap: Double = AIPanelLayout.snap) -> AIPanelLayout {
        let f = Self.clamped(f, in: c)
        var l = self
        l.corner = Corner(leading: f.midX < c.width / 2, top: f.midY < c.height / 2)
        l.anchor(f, in: c)
        if l.dx < snap && l.dy < snap { l.dx = 0; l.dy = 0 }
        return l
    }

    /// Sets dx/dy so that `f` stays where it is relative to the current corner.
    mutating func anchor(_ f: CGRect, in c: CGSize) {
        let m = Self.margin
        dx = max(0, corner.leading ? Double(f.minX) - m : Double(c.width) - m - Double(f.maxX))
        dy = max(0, corner.top ? Double(f.minY) - Self.topMargin : Double(c.height) - m - Double(f.maxY))
    }

    /// Dragging a bottom corner handle by `t` from the frame `start` (the panel's frame when the drag began).
    /// The opposite edges stay put; size is clamped to the limits and to the container.
    func resized(from start: CGRect, by t: CGSize, leadingHandle: Bool, in c: CGSize) -> AIPanelLayout {
        let m = CGFloat(Self.margin)
        let maxW = min(Self.maxSize.width, leadingHandle ? start.maxX - m : c.width - m - start.minX)
        let maxH = min(Self.maxSize.height, c.height - m - start.minY)
        let w = max(min(Self.minSize.width, maxW), min(maxW, start.width + (leadingHandle ? -t.width : t.width)))
        let h = max(min(Self.minSize.height, maxH), min(maxH, start.height + t.height))
        let f = CGRect(x: leadingHandle ? start.maxX - w : start.minX, y: start.minY, width: w, height: h)
        var l = self
        l.width = Double(w); l.height = Double(h); l.collapsed = false
        l.anchor(f, in: c)
        return l
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    // MARK: Persistence

    /// The saved layout, or the default. Undecodable data falls back to the default; the old sidebar width
    /// becomes the panel width the first time.
    static func load(_ d: UserDefaults = Pref.store) -> AIPanelLayout {
        if let s = d.string(forKey: Pref.aiFloat), let l = decode(s) { return l }
        var l = AIPanelLayout()
        if let w = d.object(forKey: Pref.legacyAIWidth) as? Double, w > 0 {
            l.width = min(max(w, Double(minSize.width)), Double(maxSize.width))
            d.removeObject(forKey: Pref.legacyAIWidth)
            d.set(l.encoded, forKey: Pref.aiFloat)
        }
        return l
    }

    func save(_ d: UserDefaults = Pref.store) { d.set(encoded, forKey: Pref.aiFloat) }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Tolerant decode: missing fields take their defaults, non-finite or negative numbers are reset.
    static func decode(_ s: String) -> AIPanelLayout? {
        guard let data = s.data(using: .utf8),
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var l = AIPanelLayout()
        func num(_ k: String) -> Double? { (o[k] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        if let c = (o["corner"] as? String).flatMap(Corner.init(rawValue:)) { l.corner = c }
        if let v = num("dx"), v >= 0 { l.dx = v }
        if let v = num("dy"), v >= 0 { l.dy = v }
        if let v = num("width"), v > 0 { l.width = v }
        if let v = num("height"), v > 0 { l.height = v }
        if let v = o["collapsed"] as? Bool { l.collapsed = v }
        return l
    }
}
