import SwiftUI

/// The inspector's layout grid. Every row, header and search field lines up on these.
extension UI {
    /// Left/right inset of inspector content (section headers, rows, search field, page header).
    static let inset: CGFloat = 14
    /// Width of the property-label column.
    static let labelWidth: CGFloat = 84
    /// Height of fields, menus, segmented controls.
    static let rowHeight: CGFloat = 26
    /// Height of section headers.
    static let headerHeight: CGFloat = 30
    /// Gap between rows within a section.
    static let rowSpacing: CGFloat = 6
    /// Indent of a nested object's / list row's fields. The label column shrinks by it so editors stay aligned.
    static let nestIndent: CGFloat = 10
}

private struct InspectorIndentKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// How far the current rows are indented (nested objects); used to keep the editor column aligned.
    var inspectorIndent: CGFloat {
        get { self[InspectorIndentKey.self] }
        set { self[InspectorIndentKey.self] = newValue }
    }
}
