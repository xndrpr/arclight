import Foundation
import Metal
import QuartzCore

/// Frame timings of a scene played the way the editor plays it (`arclight bench`).
public struct BenchResult: Sendable {
    public var frames: Int
    /// Time spent building the frame on the calling thread (evaluate + encode), ms per frame.
    public var cpuMean: Double, cpuP95: Double
    /// Time from the start of the frame until the GPU finished it, ms per frame.
    public var totalMean: Double, totalP95: Double
}

extension Renderer {
    /// Plays `scene` from 0 at `fps` for `frames` frames into an offscreen target of the scene's size × `scale`,
    /// as a draft (no motion blur), waiting for each frame. The first frame (loading) is reported apart.
    public func bench(
        scene: Scene, project: Project, assets: URL?, frames: Int, fps: Double, scale: Double = 1
    ) throws -> (first: Double, result: BenchResult) {
        let (cw, ch) = project.size(for: scene)
        let w = max(1, Int(Double(cw) * scale)), h = max(1, Int(Double(ch) * scale))
        let t = try makeTargets(width: w, height: h)
        let od = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.outFormat, width: w, height: h, mipmapped: false)
        od.usage = [.renderTarget, .shaderRead]; od.storageMode = .private
        guard let out = device.makeTexture(descriptor: od) else { throw RenderError.readback }
        let saved = draft
        draft = true
        defer { draft = saved }
        var cpu: [Double] = [], total: [Double] = []
        var first = 0.0
        for i in 0...max(frames, 1) {
            guard let cb = queue.makeCommandBuffer() else { throw RenderError.readback }
            let t0 = CACurrentMediaTime()
            encode(
                scene: scene, project: project, assets: assets, time: Double(i) / fps, scale: Double(w) / Double(cw),
                transparent: false, commandBuffer: cb, targets: t, output: out)
            let t1 = CACurrentMediaTime()
            cb.commit()
            cb.waitUntilCompleted()
            let t2 = CACurrentMediaTime()
            if i == 0 { first = (t2 - t0) * 1000; continue }
            cpu.append((t1 - t0) * 1000); total.append((t2 - t0) * 1000)
        }
        func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        func p95(_ a: [Double]) -> Double {
            let s = a.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))]
        }
        return (
            first,
            BenchResult(
                frames: cpu.count, cpuMean: mean(cpu), cpuP95: p95(cpu), totalMean: mean(total), totalP95: p95(total))
        )
    }
}
