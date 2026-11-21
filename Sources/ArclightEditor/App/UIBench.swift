import AppKit
import ArclightCore
import QuartzCore
import SwiftUI

/// `arclight uibench <project>`: how long the editor's main thread is busy after common actions, measured off screen
/// with the whole editor laid out and drawn. `first draw` is the time until the change is laid out and drawn;
/// `busy` adds the main-thread work of the next `settle` seconds (deferred updates, async results) beyond what an
/// idle window of the same length just before the action had. Development only. `UIBENCH_LOOP=<action>` repeats
/// one action for profiling.
public enum UIBench {
    public static func run(project: String) -> Int32 {
        Offscreen.startApp()
        UserDefaults.standard.setVolatileDomain(
            EditorSnapshot.volatile(theme: nil, aiOpen: true), forName: UserDefaults.argumentDomain)
        let t0 = CACurrentMediaTime()
        let doc: EditorDocument
        do { doc = try Offscreen.openDocument(project) } catch {
            FileHandle.standardError.write("cannot open project: \(error)\n".data(using: .utf8)!)
            return 1
        }
        let tDoc = CACurrentMediaTime()
        let w = Offscreen.window(NSSize(width: 1600, height: 1000))
        let host = Offscreen.host(EditorView(doc: doc), in: w)
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let tShown = CACurrentMediaTime()
        print(
            String(
                format: "open project: load %.0f ms, first window draw %.0f ms", (tDoc - t0) * 1000,
                (tShown - tDoc) * 1000))
        Offscreen.pump(4, step: 0.05) { host.layoutSubtreeIfNeeded() }
        let meter = BusyMeter()
        let settle = 0.6

        func draw() {
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            w.displayIfNeeded()
        }
        func idle() -> Double {
            meter.reset()
            Offscreen.pump(settle, step: 0.01)
            return meter.busy * 1000
        }

        let noise = [idle(), idle(), idle()].sorted()[1]
        print(String(format: "idle main-thread work: %.1f ms per %.1f s", noise, settle))
        print("action                         first draw (median / max)    busy (median / max)")

        let only = ProcessInfo.processInfo.environment["UIBENCH_ONLY"]
        func measure(_ name: String, n: Int = 8, prepare: (Int) -> Void = { _ in }, _ change: (Int) -> Void) {
            if let only, !name.contains(only) { return }
            var first: [Double] = [], busy: [Double] = []
            for i in 0..<n {
                prepare(i)
                draw()
                _ = idle()
                let before = idle()
                let t0 = CACurrentMediaTime()
                change(i)
                draw()
                let f = (CACurrentMediaTime() - t0) * 1000
                first.append(f)
                busy.append(f + max(0, idle() - before))
            }
            func stat(_ v: [Double]) -> String {
                let s = v.sorted()
                return String(format: "%6.1f / %6.1f ms", s[s.count / 2], s.last!)
            }
            print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + " " + stat(first) + "        " + stat(busy))
        }

        let ids = doc.scene.nodes.prefix(8).map(\.id)
        let scenes = doc.store.orderedScenes.prefix(6).map(\.id)
        let chats = doc.chats.list.sorted { $0.messages > $1.messages }.prefix(2).map(\.id)
        // A reply as the model writes it: inline Markdown, a new paragraph every few sentences.
        let words = Array(repeating: "The quick brown fox jumps over the lazy dog, then **reads** a `scene` and writes.", count: 4)
            .joined(separator: " ").split(separator: " ").map(String.init) + ["\n\n"]
        var k = 0
        func streamFrame(_ c: ChatController) {
            c.replay((0..<6).map { _ in k += 1; return .text(words[k % words.count] + (words[k % words.count] == "\n\n" ? "" : " ")) })
        }
        if let loop = ProcessInfo.processInfo.environment["UIBENCH_LOOP"] {
            if loop == "stream" || loop == "type", let first = chats.first {
                Pref.store.set("chat", forKey: Pref.aiPanelTab)
                doc.chats.select(first)
            }
            for i in 0..<400 {
                switch loop {
                case "stream": streamFrame(doc.chats.active); Offscreen.pump(1 / 30)
                case "type": doc.chats.active.draft += "a"; Offscreen.pump(1 / 30)
                case "select": doc.selection = ids[i % ids.count]
                case "workspace": doc.setWorkspace(i % 2 == 0 ? .thumbnail : .motion)
                case "scene": doc.open(scene: scenes[i % scenes.count])
                case "idle": Offscreen.pump(0.05)
                case "scrub": doc.scrub(to: Double(i % 120) * 0.05, tolerance: 0); Offscreen.pump(1 / 60, step: 1 / 240)
                default: doc.selection = ids[i % ids.count]
                }
                draw()
                if let p = Double(ProcessInfo.processInfo.environment["UIBENCH_PAUSE"] ?? "") { Offscreen.pump(p) }
            }
            return 0
        }
        measure("select a layer") { i in doc.selection = ids.isEmpty ? nil : ids[i % ids.count] }
        measure("move playhead (paused)") { i in doc.time = Double(i % 5) * 0.5 }
        // A drag across the ruler: 60 steps a second for half a second; the main-thread work per step.
        if only == nil || "scrub drag (per step)".contains(only!) {
            var perStep: [Double] = []
            for run in 0..<4 {
                _ = idle()
                meter.reset()
                let direct = ProcessInfo.processInfo.environment["UIBENCH_SCRUB_DIRECT"] != nil  // how it was
                for k in 0..<30 {
                    let t = Double(run) * 0.3 + Double(k) * 0.05
                    if direct { doc.playing = false; doc.time = t } else { doc.scrub(to: t, tolerance: 0) }
                    draw()
                    Offscreen.pump(1 / 60, step: 1 / 240)
                }
                Offscreen.pump(0.3, step: 0.01)  // the catch-up after the pointer rests
                perStep.append(meter.busy * 1000 / 30)
            }
            let s = perStep.sorted()
            print("scrub drag (per step)".padding(toLength: 30, withPad: " ", startingAt: 0)
                + String(format: " %6.1f / %6.1f ms", s[s.count / 2], s.last!))
        }
        measure("open another scene") { i in doc.open(scene: scenes[(i + 1) % scenes.count]) }
        measure("AI tab Chat ⇄ Activity") { i in
            Pref.store.set(i % 2 == 0 ? "activity" : "chat", forKey: Pref.aiPanelTab)
        }
        measure("left tab Scenes ⇄ History", n: 6) { i in doc.leftTab = i % 2 == 0 ? "history" : "scenes" }
        doc.leftTab = "scenes"
        measure("Motion → Thumbnails", n: 5, prepare: { _ in doc.setWorkspace(.motion) }) { _ in
            doc.setWorkspace(.thumbnail)
        }
        measure("Thumbnails → Motion", n: 5, prepare: { _ in doc.setWorkspace(.thumbnail) }) { _ in
            doc.setWorkspace(.motion)
        }
        doc.setWorkspace(.motion)

        Pref.store.set("chat", forKey: Pref.aiPanelTab)
        if chats.count == 2 {
            measure("chat: open another chat", n: 6) { i in doc.chats.select(chats[i % 2]) }
            doc.chats.select(chats[0])
            let c = doc.chats.active
            measure("chat: stream one frame", n: 20) { _ in streamFrame(c) }
            measure("chat: type a character", n: 20) { _ in c.draft += "a" }
        }
        w.orderOut(nil)
        return 0
    }
}

/// Main-thread busy time: the run loop's work between waking (or entering) and going back to sleep (or leaving).
private final class BusyMeter {
    private(set) var busy = 0.0
    private var began: Double?
    private var observer: CFRunLoopObserver?

    init() {
        let wake: CFRunLoopActivity = [.entry, .afterWaiting]
        observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity([.entry, .afterWaiting, .beforeWaiting, .exit]).rawValue, true, 0
        ) { [unowned self] _, activity in
            let now = CACurrentMediaTime()
            if wake.contains(activity) {
                began = now
            } else if let b = began {
                busy += now - b
                began = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func reset() { busy = 0; began = nil }
}
