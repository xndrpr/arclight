import AppKit
import SwiftUI

/// Content view for every Arclight window.
///
/// The windows use `.fullSizeContentView` with a transparent title bar, so the top 28 pt of the SwiftUI content sit
/// in the title-bar region. There AppKit asks the view under the pointer `mouseDownCanMoveWindow`; a plain
/// `NSHostingView` says yes, so a press that moves even a point (trackpad tap-to-click while the finger is still
/// moving) turns into a window drag and the click is eaten. Arclight windows never move from their content: only
/// `WindowDragArea` (placed behind empty top-bar / header space) drags the window.
final class AppHostingView<Content: View>: NSHostingView<Content>, ThemedWindowContent {
    /// Set once, right after creation (`AppWindows.configure`).
    nonisolated(unsafe) var windowBackground: WindowBackground = .bg

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Which palette colour fills a window behind its content (visible while resizing and under transparent areas).
enum WindowBackground {
    case bg, panel
    func color(_ p: Palette) -> Color { self == .panel ? p.panel : p.bg }
}

/// Content views that know their window's themed background (`AppTheme.apply` repaints those windows).
protocol ThemedWindowContent: AnyObject {
    var windowBackground: WindowBackground { get }
}

enum AppWindows {
    /// The editor window's style; the click probes build their titled windows the same way.
    static let editorStyle: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]

    /// Standard setup for an Arclight window: transparent full-size title bar, never movable by its background,
    /// themed appearance and background, `AppHostingView` content.
    /// `fillsTitlebar`: the content starts at the window's top edge, with no title-bar safe area (the editor's top
    /// bar lives in that row). Without it SwiftUI scroll views stretch up under the title bar and invisibly cover
    /// whatever is drawn there — the top bar and tab strips — so clicks land on a scroll view instead of a button.
    static func configure<V: View>(
        _ w: NSWindow, background: WindowBackground = .bg, fillsTitlebar: Bool = false, content: V
    ) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        let host = AppHostingView(rootView: content)
        host.windowBackground = background
        if fillsTitlebar { host.safeAreaRegions = [] }
        w.contentView = host
        AppTheme.style(w)
    }

    /// A centred Arclight window (welcome, New Project, Settings, Install guide), shown and made key.
    static func open<V: View>(
        width: CGFloat, height: CGFloat, resizable: Bool = false, title: String? = nil,
        background: WindowBackground = .bg, content: V
    ) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: style, backing: .buffered,
            defer: false)
        if let title { w.title = title }
        configure(w, background: background, content: content)
        w.center()
        w.makeKeyAndOrderFront(nil)
        return w
    }

    /// The editor's top bar lives *in* the title-bar row, next to the traffic lights. An empty compact unified
    /// toolbar makes that row tall enough and centres the traffic lights vertically in it.
    static func addTitlebarToolbar(to w: NSWindow, identifier: String) {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .unifiedCompact
        w.titlebarSeparatorStyle = .none
    }
}

/// What a double-click on a title bar does (System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to").
enum TitlebarDoubleClick: Equatable {
    case zoom, minimize, none

    /// `AppleActionOnDoubleClick` ("Maximize" / "Fill", "Minimize", "None"); older systems only have the
    /// `AppleMiniaturizeOnDoubleClick` bool. Unset means zoom.
    static func action(actionOnDoubleClick: String?, miniaturizeOnDoubleClick: Bool?) -> TitlebarDoubleClick {
        switch actionOnDoubleClick?.lowercased() {
        case "minimize": return .minimize
        case "none": return .none
        case "maximize", "fill", "zoom": return .zoom
        default: return miniaturizeOnDoubleClick == true ? .minimize : .zoom
        }
    }

    static var current: TitlebarDoubleClick {
        let d = Pref.store
        return action(
            actionOnDoubleClick: d.string(forKey: "AppleActionOnDoubleClick"),
            miniaturizeOnDoubleClick: d.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    func perform(on w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen) else { return }
        switch self {
        case .zoom: if w.styleMask.contains(.resizable) { w.zoom(nil) }
        case .minimize: if w.styleMask.contains(.miniaturizable) { w.miniaturize(nil) }
        case .none: break
        }
    }
}

/// Empty space that moves the window when dragged and zooms it on a double-click, like a title bar.
/// Put it in the `.background` of a top bar / header so buttons and fields in front keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) {}

    final class DragView: NSView {
        // We start the drag ourselves (below) so it also works under the title-bar strip.
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            endEditing()
            if e.clickCount == 2 { TitlebarDoubleClick.current.perform(on: w); return }
            w.performDrag(with: e)
        }
    }
}
