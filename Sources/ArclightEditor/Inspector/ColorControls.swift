import AppKit
import ArclightCore
import SwiftUI

/// Colour swatch (opens the system colour panel) + hex field + theme colour menu. A value that uses a theme
/// token (`$fg`) shows as a chip: click it to edit the token itself (every layer using it changes) or unlink.
struct ColorField: View {
    @ObservedObject var doc: EditorDocument
    let value: String
    /// Offer the theme colour menu (off when editing a token's own value).
    var tokens = true
    let commit: (String) -> Void

    private var tokenKey: String? {
        guard tokens, value.hasPrefix("$") else { return nil }
        let k = String(value.dropFirst())
        return doc.project.theme[k] != nil ? k : nil
    }

    var body: some View {
        let resolved = tokenKey.flatMap { doc.project.theme[$0] } ?? doc.renderer.evaluator.resolve(.string(value))
        let colorTokens = colorTokenKeys(doc.project.theme)
        HStack(spacing: 6) {
            Button {
                ColorPanelBridge.shared.open(color: Color(arclight: resolved) ?? .white, doc: doc) { commit($0.hex) }
            } label: {
                ColorSwatch(color: Color(arclight: resolved))
            }
            .buttonStyle(.plain).cursor(.pointingHand)
            .help(tokenKey.map { "Pick a colour for this layer only (unlinks $\($0))" } ?? "Pick a colour")
            if let k = tokenKey {
                TokenChip(doc: doc, key: k, unlink: { commit((Color(arclight: resolved) ?? .white).hex) }, use: commit)
            } else {
                TextCommitField(text: value, mono: true, placeholder: "#RRGGBB", commit: commit).frame(minWidth: 64)
            }
            if tokenKey == nil && tokens && !colorTokens.isEmpty {
                Menu {
                    Section("Theme colours") {
                        ForEach(colorTokens, id: \.self) { t in
                            Button(tokenMenuTitle(t) + (value == "$" + t ? "  ✓" : "")) { commit("$" + t) }
                        }
                    }
                } label: {
                    Image(systemName: "swatchpalette").font(.system(size: 11)).foregroundStyle(UI.dim)
                        .frame(width: 20, height: UI.rowHeight).hitArea()
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).fixedSize()
                .help("Use a theme colour (follows the project theme)").cursor(.pointingHand)
            }
        }
    }
}

/// 26 pt colour square over a transparency checker.
private struct ColorSwatch: View {
    let color: Color?
    var body: some View {
        ZStack {
            CheckerSwatch()
            RoundedRectangle(cornerRadius: 5).fill(color ?? .clear)
        }
        .frame(width: UI.rowHeight, height: UI.rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.fieldBorder, lineWidth: 1))
        .hitArea()
    }
}

/// A value linked to a theme token. Click to edit that token in place.
private struct TokenChip: View {
    @ObservedObject var doc: EditorDocument
    let key: String
    let unlink: () -> Void
    var use: ((String) -> Void)? = nil
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 6) {
                Text("$" + key).font(UI.mono).foregroundStyle(UI.text).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "paintpalette").font(.system(size: 9.5)).foregroundStyle(hover ? UI.dim : UI.faint)
            }
            .padding(.horizontal, 8).frame(minWidth: 56).frame(height: UI.rowHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UI.hover : UI.field))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                    UI.fieldBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
        .help("Theme colour $\(key) — click to edit it for every layer that uses it")
        .popover(isPresented: $open, arrowEdge: .leading) {
            TokenPopover(
                doc: doc, key: key,
                unlink: {
                    unlink(); open = false
                },
                use: use.map { u in
                    {
                        u($0); open = false
                    }
                })
        }
    }
}

/// Edits one theme colour token from a layer's property.
private struct TokenPopover: View {
    @ObservedObject var doc: EditorDocument
    let key: String
    let unlink: () -> Void
    var use: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("$" + key).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(
                    UI.text)
                Text("Theme colour" + (ThemePresets.describe(key).map { " · " + $0 } ?? "")).font(UI.small)
                    .foregroundStyle(UI.dim)
            }
            ColorField(doc: doc, value: doc.project.theme[key]?.string ?? "", tokens: false) {
                doc.setThemeToken(key, .string($0))
            }
            Text("Changing it restyles every layer and scene that uses $\(key).").font(UI.small).foregroundStyle(
                UI.faint
            )
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Unlink this layer", action: unlink).buttonStyle(PillButtonStyle()).fixedSize()
                    .help("Use the plain colour here, so later theme changes don't affect this layer")
                Spacer()
                if let use {
                    Menu {
                        ForEach(colorTokenKeys(doc.project.theme), id: \.self) { t in
                            Button(tokenMenuTitle(t)) { use("$" + t) }
                        }
                    } label: {
                        Text("Use another…").font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
                    }
                    .menuStyle(.borderlessButton).fixedSize().cursor(.pointingHand)
                    .help("Link this layer to a different theme colour")
                }
            }
        }
        .popoverChrome(width: 280)
    }
}

/// Transparent-colour checkerboard behind swatches.
struct CheckerSwatch: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 5
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(UI.border))
                }
            }
        }
        .background(UI.raised)
    }
}

/// Drives NSColorPanel for one swatch at a time; one undo step per panel session.
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Color) -> Void)?
    private weak var doc: EditorDocument?
    private var closeObserver: Any?

    func open(color: Color, doc: EditorDocument, onChange: @escaping (Color) -> Void) {
        finish()
        self.onChange = onChange
        self.doc = doc
        doc.beginGesture()
        let p = NSColorPanel.shared
        p.showsAlpha = true
        p.setTarget(nil); p.setAction(nil)
        p.color = NSColor(color)
        p.setTarget(self); p.setAction(#selector(changed(_:)))
        p.isContinuous = true
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self] _ in self?.finish() }
        p.orderFront(nil)
    }

    @objc private func changed(_ p: NSColorPanel) { onChange?(Color(nsColor: p.color)) }

    private func finish() {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = nil
        doc?.endGesture()
        doc = nil; onChange = nil
    }
}

/// Theme tokens that hold a colour, sorted.
private func colorTokenKeys(_ theme: [String: JSONValue]) -> [String] {
    theme.filter { RGBA.parse($0.value) != nil }.keys.sorted()
}

/// "$key  —  meaning" for theme colour menus.
private func tokenMenuTitle(_ key: String) -> String {
    "$" + key + (ThemePresets.describe(key).map { "  —  " + $0 } ?? "")
}
