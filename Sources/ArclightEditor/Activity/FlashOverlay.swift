import ArclightCore
import SwiftUI
import simd

/// Briefly outlines layers changed outside the editor (e.g. by an AI agent) in the viewport. 2D layers only;
/// never takes clicks. `doc.flashIds` clears itself after a moment, which fades the outlines out.
struct FlashOverlay: View {
    @ObservedObject var doc: EditorDocument
    let scale: CGFloat
    @State private var pulse = false
    /// Last outlines, kept while fading out after `flashIds` clears.
    @State private var fading: [Quad] = []
    @State private var visible = false

    var body: some View {
        let quads = doc.flashIds.isEmpty ? fading : outlines()
        ZStack(alignment: .topLeading) {
            ForEach(quads, id: \.id) { q in
                Path { p in
                    p.addLines(q.pts); p.closeSubpath()
                }
                .stroke(UI.ai, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3], dashPhase: pulse ? 8 : 0))
                .shadow(color: UI.ai.opacity(0.5), radius: 4)
                Text(q.id).font(UI.monoSmall).foregroundStyle(UI.text)
                    .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 3).fill(UI.panel.opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.ai.opacity(0.8)))
                    .fixedSize()
                    .position(x: q.pts[0].x + CGFloat(q.id.count) * 3.3 + 4, y: q.pts[0].y - 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .opacity(visible ? 1 : 0)
        .onChange(of: doc.flashIds) { _, ids in
            if ids.isEmpty {
                withAnimation(.easeOut(duration: 0.5)) { visible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if doc.flashIds.isEmpty { fading = [] } }
            } else {
                fading = outlines()
                withAnimation(.easeOut(duration: 0.15)) { visible = true }
            }
        }
        .onAppear { withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) { pulse = true } }
    }

    private struct Quad { let id: String; let pts: [CGPoint] }

    private func outlines() -> [Quad] {
        doc.evaluate().compactMap { n in
            guard doc.flashIds.contains(n.node.id), !n.is3D, n.opacity > 0.001, let b = doc.renderer.localBounds(n)
            else { return nil }
            let pts = [
                CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY),
                CGPoint(x: b.minX, y: b.maxY),
            ]
            .map { p -> CGPoint in
                let w = n.world * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
                return CGPoint(x: CGFloat(w.x) * scale, y: CGFloat(w.y) * scale)
            }
            return Quad(id: n.node.id, pts: pts)
        }
    }
}
