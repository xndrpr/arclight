import Foundation
import simd

/// Perspective camera in canvas pixel space (x right, y down, z into the screen).
/// With no camera prop, the default camera views the z = 0 plane exactly 1:1 with the 2D canvas
/// (like After Effects), so 3D layers line up with 2D ones until you move it.
public struct CameraState {
    public var viewProj: simd_float4x4
    public var position: SIMD3<Float>
    public var right: SIMD3<Float>
    public var up: SIMD3<Float>
    public var forward: SIMD3<Float>
    /// Pixels on the canvas per world unit at distance 1 (multiply by 1/depth).
    public var focalPx: Float
    public var near: Float
    public var aspect: Float = 16 / 9
    // Depth of field
    var focus: Float
    var blur: Float
    var range: Float

    /// `shake`: one or a list of decaying jolts, e.g. `{"at":3.4,"y":9,"roll":0.35}` —
    /// y = vertical offset (world units), roll = degrees, decay (default 9/s), freq (default 9 Hz), duration (0.6 s).
    public static func make(_ json: JSONValue?, width w: Float, height h: Float, time T: Double = 0) -> CameraState {
        let o = json?.object ?? [:]
        func v3(_ k: String, _ d: SIMD3<Float>) -> SIMD3<Float> {
            guard let a = o[k]?.doubles, a.count >= 3 else { return d }
            return SIMD3(Float(a[0]), Float(a[1]), Float(a[2]))
        }
        let fov = Float(o["fov"]?.double ?? 40) * .pi / 180
        let t = tan(fov / 2)
        let defaultDist = (h / 2) / t
        let target = v3("target", SIMD3(w / 2, h / 2, 0))
        var eye = v3("position", SIMD3(w / 2, h / 2, -defaultDist))
        var shakeRoll: Float = 0
        let shakes = o["shake"].map { $0.array ?? [$0] } ?? []
        for s in shakes {
            guard let so = s.object, let at = so["at"]?.double else { continue }
            let k = T - at
            guard k > 0, k < (so["duration"]?.double ?? 0.6) else { continue }
            let d = exp(-k * (so["decay"]?.double ?? 9))
            let f = (so["freq"]?.double ?? 9) * 2 * .pi
            eye.y += Float((so["y"]?.double ?? 8) * d * sin(k * f))
            shakeRoll += Float((so["roll"]?.double ?? 0.35) * d * sin(k * f * 1.27))
        }
        var f = simd_normalize(target - eye)
        if !f.x.isFinite { f = SIMD3(0, 0, 1) }
        var worldUp = SIMD3<Float>(0, -1, 0)
        if abs(simd_dot(f, worldUp)) > 0.999 { worldUp = SIMD3(0, 0, 1) }
        var r = simd_normalize(simd_cross(f, worldUp))
        var u = simd_cross(r, f)
        let roll = (Float(o["roll"]?.double ?? 0) + shakeRoll) * .pi / 180
        if roll != 0 {
            let r2 = r * cos(roll) + u * sin(roll)
            u = u * cos(roll) - r * sin(roll)
            r = r2
        }
        let near = Float(o["near"]?.double ?? 1), far = Float(o["far"]?.double ?? 100_000)
        // Rows: camera-space x, y, z dotted with (p - eye).
        let view = simd_float4x4(rows: [
            SIMD4(r.x, r.y, r.z, -simd_dot(r, eye)),
            SIMD4(u.x, u.y, u.z, -simd_dot(u, eye)),
            SIMD4(f.x, f.y, f.z, -simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1),
        ])
        let aspect = w / h, fy = 1 / t
        let proj = simd_float4x4(rows: [
            SIMD4(fy / aspect, 0, 0, 0),
            SIMD4(0, fy, 0, 0),
            SIMD4(0, 0, far / (far - near), -near * far / (far - near)),
            SIMD4(0, 0, 1, 0),
        ])
        let dof = o["dof"]?.object ?? [:]
        let focus = Float(dof["focus"]?.double ?? Double(simd_length(target - eye)))
        return CameraState(
            viewProj: proj * view, position: eye, right: r, up: u, forward: f,
            focalPx: (h / 2) / t, near: near, aspect: aspect,
            focus: focus, blur: Float(dof["blur"]?.double ?? 0), range: Float(dof["range"]?.double ?? 0.5))
    }

    public func depth(_ p: SIMD3<Float>) -> Float { simd_dot(p - position, forward) }

    /// World-space ray through a canvas pixel (x right, y down, canvas `width` × `height`): origin at the eye,
    /// unit direction. Inverse of `viewProj` + the viewport mapping (ndc.x = 2x/W − 1, ndc.y = 1 − 2y/H).
    public func ray(at p: SIMD2<Float>, width w: Float, height h: Float) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        let d = forward + right * ((p.x - w / 2) / focalPx) + up * ((h / 2 - p.y) / focalPx)
        return (position, simd_normalize(d))
    }
}
