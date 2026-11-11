import AppKit
import ArclightCore
import SwiftUI

/// `arclight snapshot <project> --out ui.png`: renders the editor UI (or one panel, `--panel`) to a PNG without
/// showing anything on screen. Used to check UI changes during development and in CI (Scripts/verify.sh).
///
/// Options: `--time`, `--select <layer id>`, `--tab scenes|history|assets|ai`, `--setup` (see `applySetup`),
/// `--theme <AppTheme raw value>`, `--size WxH`, `--panel settings|installhelp|shortcuts|inspector|themepopover|timeline|
/// newproject|welcome|templates|inserttemplate|savetemplate` (library panels fill `--size`, e.g. 980x640).
public enum EditorSnapshot {
    public struct Options {
        public var project: String
        public var out: String
        public var time: Double?
        public var select: String?
        public var tab: String?
        public var panel: String?
        public var width = 1600
        public var height = 1000
        public var setup: String?
        /// App theme raw value (`AppTheme`), e.g. "light", "gruvboxDark". Not persisted.
        public var theme: String?
        public init(project: String, out: String) { self.project = project; self.out = out }
    }

    public static func run(_ o: Options) -> Int32 {
        Offscreen.startApp()
        var openAI = false, aiLayout = ""
        UserDefaults.standard.setVolatileDomain(
            volatile(theme: o.theme, aiOpen: false), forName: UserDefaults.argumentDomain)
        AppTheme.apply(AppTheme.stored)  // --theme lives in the volatile domain, so nothing is saved
        let doc: EditorDocument
        do { doc = try Offscreen.openDocument(o.project) } catch {
            FileHandle.standardError.write("cannot open project: \(error)\n".data(using: .utf8)!)
            return 1
        }
        if let t = o.time { doc.time = t }
        if let s = o.select { doc.selection = s }
        if let tab = o.tab { if ["ai", "activity"].contains(tab) { openAI = true } else { doc.leftTab = tab } }
        applySetup(o.setup, doc: doc, openAI: &openAI, layout: &aiLayout)
        UserDefaults.standard.setVolatileDomain(
            volatile(theme: o.theme, aiOpen: openAI, layout: aiLayout), forName: UserDefaults.argumentDomain)

        let size = NSSize(width: o.width, height: o.height)
        let w = Offscreen.window(size)
        let host = Offscreen.host(rootView(o, doc: doc), in: w)
        AppTheme.style(w)
        w.orderFrontRegardless()
        Offscreen.pump(1.2, step: 0.05) { host.layoutSubtreeIfNeeded() }
        let drawing = Offscreen.settledDrawing(host)

        guard let image = Offscreen.capture(host, in: w, size: size, doc: doc, time: doc.viewTime, drawing: drawing)
        else { return 1 }
        w.orderOut(nil)
        guard let png = Offscreen.png(image) else { return 1 }
        do { try png.write(to: URL(fileURLWithPath: o.out)) } catch { return 1 }
        print(o.out)
        return 0
    }

    private static func rootView(_ o: Options, doc: EditorDocument) -> AnyView {
        switch o.panel {
        case "settings": return AnyView(SettingsView(doc: doc, initialTab: o.tab))
        case "installhelp": return AnyView(InstallHelpView(close: {}))
        case "shortcuts": return AnyView(ShortcutsSheet(isPresented: .constant(true)))
        case "inspector": return AnyView(InspectorView(doc: doc).frame(width: CGFloat(o.width)))
        case "themepopover": return AnyView(ThemePopoverSnapshot(doc: doc))
        case "timeline": return AnyView(TimelineView(doc: doc))
        case "newproject": return AnyView(NewProjectView(create: { _ in }, cancel: {}))
        case "welcome": return AnyView(WelcomeView(open: {}, new: {}, openURL: { _ in }))
        case "templates": return AnyView(TemplateGallery(doc: doc, mode: .newScene, close: {}, initial: o.select))
        case "inserttemplate": return AnyView(TemplateGallery(doc: doc, mode: .insert, close: {}))
        case "savetemplate": return AnyView(SaveTemplateSheet(doc: doc, scene: doc.scene, close: {}))
        default: return AnyView(EditorView(doc: doc))
        }
    }

    /// Settings that must not leak in from the user's real preferences.
    static func volatile(theme: String?, aiOpen: Bool, layout: String = "") -> [String: Any] {
        var d: [String: Any] = [Pref.aiPanel: aiOpen, Pref.aiFloat: layout, Pref.legacyAIWidth: 0]
        if let theme { d[Pref.theme] = theme }
        return d
    }

    /// `--setup` takes comma-separated items: `zoom:3`, `ai` (open the floating AI panel), `ai:collapsed`,
    /// `ai:bottomLeading` (or any corner), `agent[:idle|reading|editing]` (a fake agent session on this project),
    /// `agents:N` (N fake sessions). Real sessions are never shown.
    static func applySetup(_ setup: String?, doc: EditorDocument, openAI: inout Bool, layout: inout String) {
        let items = (setup ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var fakes: [AgentPresence] = []
        let clients = ["claude-code", "cursor-vscode", "codex-mcp-client", "windsurf"]
        func agent(_ i: Int, _ state: String) -> AgentPresence {
            let now = Date()
            let project = i == 0 ? Presence.key(doc.url) : "/Volumes/Projects/Launch.arclight"
            var a = AgentPresence(
                pid: Int32(90000 + i), client: clients[i % clients.count], clientVersion: i == 0 ? "2.1.4" : nil,
                started: now.addingTimeInterval(-Double(300 + 600 * i)), project: project)
            a.begin("scene_apply", writes: true)
            a.end(
                summary: "set stat (size, color); add crowd", wrote: true, ok: true, project: project,
                at: now.addingTimeInterval(-42))
            switch state {
            case "editing": a.begin("scene_apply", writes: true)
            case "reading": a.begin("render_frames", writes: false)
            default: break
            }
            return a
        }
        for it in items {
            if it == "ai" {
                openAI = true
            } else if it.hasPrefix("ai:") {
                openAI = true
                var l = AIPanelLayout()
                let arg = String(it.dropFirst(3))
                if arg == "collapsed" {
                    l.collapsed = true
                } else if let c = AIPanelLayout.Corner(rawValue: arg) {
                    l.corner = c
                }
                layout = l.encoded
            } else if it == "agent" || it.hasPrefix("agent:") {
                fakes = [agent(0, String(it.dropFirst(6)))]
            } else if it.hasPrefix("agents:"), let n = Int(it.dropFirst(7)) {
                fakes = (0..<max(0, n)).map { agent($0, "") }
            } else if it.hasPrefix("zoom:"), let f = Double(it.dropFirst(5)) {
                doc.zoomTimeline(by: f)
            }
        }
        AgentMonitor.shared.fake(fakes)
    }
}
