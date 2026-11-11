import AppKit
import ArclightCore
import SwiftUI

/// Horizontal splitter for the timeline height: a 1px line with a 7px grab area that lives in the
/// layout (not an overlay), so the Metal viewport can't steal its clicks.
struct ResizeHandle: View {
    @Binding var height: Double
    @State private var start: Double?
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(hover || start != nil ? UI.faint : UI.border).frame(height: hover || start != nil ? 2 : 1)
        }
        .frame(height: 7).hitArea()
        .onHover { hover = $0 }
        .cursor(.resizeUpDown)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { g in
                if start == nil { start = height }
                height = min(max(start! - Double(g.translation.height), 140), 700)
            }.onEnded { _ in start = nil }
        )
        .zIndex(10)
    }
}

/// Vertical splitter for the side panels (same idea as `ResizeHandle`). Double-click resets the width.
struct SideResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let growsRight: Bool
    var defaultWidth: Double? = nil
    @State private var start: Double?
    @State private var press = PressTracker()
    @State private var hover = false
    var body: some View {
        ZStack {
            Color.clear
            Rectangle().fill(hover || start != nil ? UI.faint : UI.border).frame(width: hover || start != nil ? 2 : 1)
        }
        .frame(width: 7).hitArea()
        .onHover { hover = $0 }
        .cursor(.resizeLeftRight)
        // One press gesture for both: a TapGesture(count: 2) next to a 1 pt drag lost every double-click whose
        // pointer moved a little (trackpad taps), and the jitter resized the panel instead.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { g in
                if !press.isPressed { press.begin() }
                guard press.update(g.translation) else { return }
                if start == nil { start = width }
                let d = Double(g.translation.width) * (growsRight ? 1 : -1)
                width = min(max(start! + d, range.lowerBound), range.upperBound)
            }.onEnded { _ in
                start = nil
                if press.end(), (NSApp.currentEvent?.clickCount ?? 1) >= 2, let d = defaultWidth {
                    withMotion(UI.snappy) { width = d }
                }
            }
        )
        .zIndex(10)
        .help("Drag to resize · double-click to reset")
    }
}
