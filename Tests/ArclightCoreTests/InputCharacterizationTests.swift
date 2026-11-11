import AppKit
import Foundation
import Testing

@testable import ArclightEditor

/// Boundaries of the click/drag rules and the floating AI panel geometry. These encode fixes for real lost-click
/// and layout bugs (see CONTRIBUTING.md, "UI rules that each fixed a real bug"); keep the numbers unless the behaviour
/// is meant to change.
@Suite struct InputCharacterizationTests {
    @Test func clickSlopBoundaries() {
        #expect(ClickSlop.slop == 4 && ClickSlop.fastSlop == 12 && ClickSlop.settle == 0.12)
        #expect(!ClickSlop.isDrag(distance: 3.99, elapsed: 10))
        #expect(!ClickSlop.isDrag(distance: 4, elapsed: 0.1199))
        #expect(ClickSlop.isDrag(distance: 4, elapsed: 0.12))
        #expect(!ClickSlop.isDrag(distance: 11.99, elapsed: 0))
        #expect(ClickSlop.isDrag(distance: 12, elapsed: 0))
        #expect(ClickSlop.distance(CGSize(width: 3, height: 4)) == 5)
    }

    @Test func pressTrackerLatchesAndResets() {
        var p = PressTracker()
        let idleEnd = p.end()
        #expect(!p.isPressed && !idleEnd)  // no press: not a click
        let early = p.update(CGSize(width: 50, height: 0))  // updates before begin are ignored
        #expect(!early)
        let t0 = Date()
        p.begin(now: t0)
        #expect(p.isPressed)
        let slow = p.update(CGSize(width: 5, height: 0), now: t0.addingTimeInterval(0.05))
        let settled = p.update(CGSize(width: 5, height: 0), now: t0.addingTimeInterval(0.2))
        let back = p.update(.zero, now: t0.addingTimeInterval(0.3))  // stays a drag after coming back
        #expect(!slow && settled && back)
        let dragEnd = p.end()
        #expect(!dragEnd && !p.isPressed && !p.dragging)
        p.begin(now: t0)
        let click = p.end()
        #expect(click)
    }

    @Test func scrollGuardRules() {
        // Pressed, zero movement, any phase except momentum: dropped.
        for phase: NSEvent.Phase in [.mayBegin, .cancelled, .began, .changed, .ended, []] {
            #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 0, phase: phase, momentum: []), "\(phase)")
        }
        // mayBegin / cancelled are dropped even with a stray delta; other phases keep real movement.
        #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 1, dy: 0, phase: .mayBegin, momentum: []))
        #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 2, phase: .cancelled, momentum: []))
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 2, phase: .changed, momentum: []))
        // Momentum scrolling and unpressed events pass.
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 0, phase: [], momentum: .changed))
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: false, dx: 0, dy: 0, phase: .mayBegin, momentum: []))
    }

    @Test func aiPanelSizeLimits() {
        let c = CGSize(width: 1200, height: 900)
        var l = AIPanelLayout()
        l.width = 10; l.height = 10
        #expect(l.size(in: c) == AIPanelLayout.minSize)
        l.width = 5000; l.height = 5000
        #expect(l.size(in: c) == CGSize(width: AIPanelLayout.maxSize.width, height: 900 - 10 - 10))
        // Smaller container than the minimum (but not a sheet): the panel shrinks to fit.
        let small = CGSize(width: 420, height: 320)
        #expect(!l.isSheet(in: small) && l.size(in: small) == CGSize(width: 400, height: 300))
        // Sheet thresholds and collapsed sheet.
        #expect(l.isSheet(in: CGSize(width: 399, height: 900)) && l.isSheet(in: CGSize(width: 900, height: 299)))
        l.collapsed = true
        #expect(
            l.frame(in: CGSize(width: 300, height: 600))
                == CGRect(x: 6, y: 6, width: 288, height: AIPanelLayout.headerHeight))
    }

    @Test func aiPanelCornersAndDecoding() {
        let c = CGSize(width: 1000, height: 800)
        for corner in AIPanelLayout.Corner.allCases {
            var l = AIPanelLayout(); l.corner = corner; l.dx = 20; l.dy = 30
            let f = l.frame(in: c)
            #expect(corner.leading ? f.minX == 30 : f.maxX == 970, "\(corner)")
            #expect(corner.top ? f.minY == 40 : f.maxY == 760, "\(corner)")
            // Settling a frame where it already is: 20 and 30 are both under the 40 pt snap distance, so it snaps.
            #expect(l.settled(f, in: c).dx == 0 && l.settled(f, in: c).dy == 0)
        }
        #expect(AIPanelLayout.decode(#"{"dx":"NaN","height":-1,"collapsed":"yes"}"#) == AIPanelLayout())
        #expect(AIPanelLayout.decode("[]") == nil)
    }
}
