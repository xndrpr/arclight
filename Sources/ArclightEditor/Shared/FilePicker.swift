import AppKit
import UniformTypeIdentifiers

/// Open panels.
enum FilePicker {
    /// Asks for one file, or several when `multiple`; empty when cancelled. `types` empty allows any file.
    static func files(_ types: [UTType] = [], multiple: Bool = false, message: String? = nil) -> [URL] {
        let p = NSOpenPanel()
        if multiple { p.allowsMultipleSelection = true }
        if !types.isEmpty { p.allowedContentTypes = types }
        if let message { p.message = message }
        return p.runModal() == .OK ? p.urls : []
    }

    /// The file types a project can have in an open panel. The installed app declares `.arclight` (and the older
    /// `.apogee`) as packages, which Finder and open panels show as files, so a folders-only panel can't pick one.
    /// Plain folders stay allowed for a build that isn't bundled, where nothing declares the package types.
    static var projectTypes: [UTType] {
        ["arclight", "apogee"].compactMap { UTType(filenameExtension: $0, conformingTo: .package) } + [.folder]
    }

    /// Asks for one project (a `.arclight` or `.apogee` folder, shown as a file once the app is installed); nil
    /// when cancelled.
    static func project(message: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowedContentTypes = projectTypes
        if let message { p.message = message }
        return p.runModal() == .OK ? p.url : nil
    }

    /// Asks for one folder; nil when cancelled.
    static func folder(
        message: String? = nil, prompt: String? = nil, canCreate: Bool = false, startingAt dir: URL? = nil
    ) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        if canCreate { p.canCreateDirectories = true }
        if let message { p.message = message }
        if let prompt { p.prompt = prompt }
        if let dir { p.directoryURL = dir }
        return p.runModal() == .OK ? p.url : nil
    }
}
