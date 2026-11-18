import AppKit
import ArclightCore

/// Entry point for the GUI (`arclight` with no arguments, `arclight open <project>`, or the .app bundle).
public enum EditorApp {
    public static func run(open path: String?) {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.initialPath = path
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
