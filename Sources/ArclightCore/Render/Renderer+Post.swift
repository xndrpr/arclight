import Foundation
import Metal
import simd

extension Renderer {
    /// Bloom into `t.bloom[0]` (threshold, then a down/up mip chain) from the world with the 2D overlay over it.
    /// Returns its intensity; 0 means off.
    func encodeBloom(
        _ json: JSONValue?, source cur: MTLTexture, overlay: MTLTexture, cb: MTLCommandBuffer, t: RenderTargets
    ) -> Float {
        let bloomIntensity = Float(json?.double ?? json?["intensity"]?.double ?? 0)
        if bloomIntensity > 0 {
            let threshold = Float(json?["threshold"]?.double ?? 1)
            let levels = max(1, min(t.bloom.count, Int(json?["levels"]?.double ?? 5)))
            var p = SIMD4<Float>(threshold, 0, 1 / Float(t.width), 1 / Float(t.height))
            fullscreen(cb, target: t.bloom[0], pso: brightPSO, textures: [cur, overlay], params: &p)
            for i in 1..<levels {
                var q = SIMD4<Float>(0, 0, 1 / Float(t.bloom[i - 1].width), 1 / Float(t.bloom[i - 1].height))
                fullscreen(cb, target: t.bloom[i], pso: downPSO, textures: [t.bloom[i - 1]], params: &q)
            }
            for i in stride(from: levels - 2, through: 0, by: -1) {
                var q = SIMD4<Float>(0, 0, 1 / Float(t.bloom[i + 1].width), 1 / Float(t.bloom[i + 1].height))
                fullscreen(
                    cb, target: t.bloom[i], pso: upPSO, textures: [t.bloom[i + 1]], params: &q, loadAction: .load)
            }
        }
        return bloomIntensity
    }

    /// Parameters of the final grade (final_fs): exposure, contrast, saturation, tonemap, vignette, grain, fade.
    func grade(
        _ post: [String: JSONValue], scene: Scene, T: Double, fps: Double, aspect: Float, bloomIntensity: Float
    ) -> PostU {
        func num(_ k: String, _ d: Double) -> Float { Float(post[k]?.double ?? d) }
        let vig = post["vignette"]
        // Fade from/to a colour: {"in":0.6,"out":0.6,"color":"#0E0E0E"} (seconds, cubic in-out).
        var fade = SIMD4<Float>(0, 0, 0, 1)
        if let f = post["fade"]?.object {
            let fin = f["in"]?.double ?? 0, fout = f["out"]?.double ?? 0
            var v = 1.0
            if fin > 0 { v *= Easing("inOutCubic").apply(T / fin) }
            if fout > 0 { v *= 1 - Easing("inOutCubic").apply((T - (scene.duration - fout)) / fout) }
            let c = (RGBA.parse(f["color"]) ?? evaluator.background(scene, T: T)).linearPremultiplied()
            fade = SIMD4(c.x, c.y, c.z, Float(v))
        }
        return PostU(
            a: SIMD4(
                pow(2, num("exposure", 0)), num("contrast", 1), num("saturation", 1),
                post["tonemap"]?.bool == true ? 1 : 0),
            b: SIMD4(
                Float(vig?.double ?? vig?["amount"]?.double ?? 0), Float(vig?["softness"]?.double ?? 0.6),
                num("grain", 0), Float((T * fps).rounded().truncatingRemainder(dividingBy: 997))),
            c: SIMD4(bloomIntensity, bloomIntensity > 0 ? 1 : 0, aspect, post["gradeOverlay"]?.bool == true ? 1 : 0),
            d: fade)
    }
}
