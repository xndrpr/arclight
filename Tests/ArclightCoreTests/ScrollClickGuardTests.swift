import AppKit
import Testing

@testable import ArclightEditor

@Suite struct ScrollClickGuardTests {
    @Test func dropsZeroMovementScrollWhilePressed() {
        #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 0, phase: .mayBegin, momentum: []))
        #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 0, phase: .cancelled, momentum: []))
        #expect(ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: 0, phase: [], momentum: []))
    }

    @Test func keepsRealScrollingAndUnpressedEvents() {
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: false, dx: 0, dy: 0, phase: .mayBegin, momentum: []))
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: -4, phase: .changed, momentum: []))
        #expect(!ScrollClickGuard.shouldDrop(buttonDown: true, dx: 0, dy: -2, phase: [], momentum: .changed))
    }
}
