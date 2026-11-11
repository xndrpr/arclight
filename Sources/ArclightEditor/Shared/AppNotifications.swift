import Foundation

/// Every notification the editor posts. `object` is the `EditorDocument` unless noted.
extension Notification.Name {
    /// ⌘E: show the export sheet.
    static let showExport = Notification.Name("arclight.showExport")
    /// "?" or the keyboard button: show the shortcuts sheet.
    static let showShortcuts = Notification.Name("arclight.showShortcuts")
    /// Start renaming the project in the top bar.
    static let renameProject = Notification.Name("arclight.renameProject")
    /// Posted by the app's key handler just before Esc takes focus away from a text field (object: the text view).
    static let escapeInTextField = Notification.Name("arclight.escapeInTextField")
    /// User theme presets were saved or deleted (object: nil).
    static let themePresetsChanged = Notification.Name("arclight.themePresetsChanged")
    /// Posted by `AppTheme.apply` after the app theme changed (object: nil).
    static let appThemeChanged = Notification.Name("arclight.appThemeChanged")
}
