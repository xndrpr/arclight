import AppKit
import ArclightCore

/// Entry point for the GUI (`arclight` with no arguments, `arclight open <project>`, or the .app bundle).
public enum EditorApp {
    public static func run(open path: String?) {
        // Settings from before the rename, read once (the app's domain is its bundle id, the CLI's its name).
        LegacyMigration.migrateDefaults(domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.initialPath = path
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
