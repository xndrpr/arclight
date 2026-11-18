import AppKit
import ArclightCore
import QuartzCore
import SwiftUI

/// `arclight uibench <project>`: how long the editor's main thread is busy after common actions (toggle Performance,
/// select a layer, switch AI tabs, switch Motion ⇄ Thumbnails), measured off screen with the whole editor laid out
/// and drawn. Development only.
public enum UIBench {
    public static func run(project: String) -> Int32 {
        Offscreen.startApp()
        UserDefaults.standard.setVolatileDomain(
            EditorSnapshot.volatile(theme: nil, aiOpen: true), forName: UserDefaults.argumentDomain)
        let doc: EditorDocument
        do { doc = try Offscreen.openDocument(project) } catch {
            FileHandle.standardError.write("cannot open project: \(error)\n".data(using: .utf8)!)
            return 1
        }
        let size = NSSize(width: 1600, height: 1000)
        let w = Offscreen.window(size)
        let host = Offscreen.host(EditorView(doc: doc), in: w)
        w.orderFrontRegardless()
        Offscreen.pump(1.5, step: 0.05) { host.layoutSubtreeIfNeeded() }

        /// Runs `change`, then lets SwiftUI update, lay out and draw; the median of `n` runs in ms.
        func measure(_ name: String, n: Int = 9, _ change: (Int) -> Void) {
            var times: [Double] = []
            for i in 0..<n {
                let t0 = CACurrentMediaTime()
                change(i)
                // Let SwiftUI's transaction land (it updates on the next run-loop turn), then lay out and draw.
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                w.displayIfNeeded()
                times.append((CACurrentMediaTime() - t0) * 1000)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let s = times.sorted()
            print(String(format: "%-34@ median %6.1f ms   max %6.1f ms", name as NSString, s[s.count / 2], s.last!))
        }

        if let only = ProcessInfo.processInfo.environment["UIBENCH_LOOP"] {
            // Profiling: repeat one action for a while (sample the process meanwhile).
            let ids = doc.scene.nodes.prefix(8).map(\.id)
            for i in 0..<400 {
                switch only {
                case "select": doc.selection = ids[i % ids.count]
                case "workspace": doc.setWorkspace(i % 2 == 0 ? .thumbnail : .motion)
                default: doc.performance.toggle()
                }
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); w.displayIfNeeded()
            }
            return 0
        }
        measure("toggle Performance") { _ in doc.performance.toggle() }
        let ids = doc.scene.nodes.prefix(8).map(\.id)
        measure("select a layer") { i in doc.selection = ids.isEmpty ? nil : ids[i % ids.count] }
        measure("move playhead (paused)") { i in doc.time = Double(i % 5) * 0.5 }
        measure("AI tab Chat ⇄ Activity") { i in
            Pref.store.set(i % 2 == 0 ? "activity" : "chat", forKey: Pref.aiPanelTab)
        }
        measure("left tab Scenes ⇄ History", n: 6) { i in doc.leftTab = i % 2 == 0 ? "history" : "scenes" }
        measure("Motion ⇄ Thumbnails", n: 6) { i in doc.setWorkspace(i % 2 == 0 ? .thumbnail : .motion) }
        w.orderOut(nil)
        return 0
    }
}
