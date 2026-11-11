import Foundation
import Testing

@testable import ArclightEditor

/// Small shared editor helpers (Shared/Collections.swift, `rounded(_:places:)`).
@Suite struct EditorHelpersTests {
    @Test func safeSubscript() {
        let a = [1, 2, 3]
        #expect(a[safe: 0] == 1 && a[safe: 2] == 3)
        #expect(a[safe: 3] == nil && a[safe: -1] == nil)
    }

    @Test func uniquedKeepsFirstInOrder() {
        #expect(["b", "a", "b", "c", "a"].uniqued(by: { $0 }) == ["b", "a", "c"])
        let packs = [("basic", 1), ("brand", 2), ("basic", 3)].uniqued(by: \.0).map(\.1)
        #expect(packs == [1, 2])
        // Same result as the hand-written `reduce(into:)` dedupe it replaces.
        let xs = ["x", "y", "x", "z", "y"]
        #expect(xs.uniqued(by: { $0 }) == xs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    }

    @Test func roundedPlacesMatchesHundredths() {
        for x in [0, 1.005, 2.675, -3.14159, 9.995, 123.456, 1e-7, 0.125] {
            #expect(rounded(x, places: 2) == (x * 100).rounded() / 100)
        }
        #expect(rounded(1.23456, places: 3) == 1.235)
        #expect(rounded(7.6, places: 0) == 8)
    }
}

@Suite struct LocalEventMonitorTests {
    @Test func installAndRemove() {
        let m = LocalEventMonitor(.keyDown) { _ in nil }
        #expect(!m.isInstalled)
        m.install(); m.install()
        #expect(m.isInstalled)
        m.remove()
        #expect(!m.isInstalled)
        m.remove()
        #expect(!m.isInstalled)
    }
}
