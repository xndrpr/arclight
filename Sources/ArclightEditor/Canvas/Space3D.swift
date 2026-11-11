import ArclightCore
import Foundation
import simd

// MARK: 3D

enum Space3D {
    /// Where a ray meets the horizontal plane y = `planeY` (nil when parallel or behind the eye).
    static func hitPlane(origin o: SIMD3<Float>, dir d: SIMD3<Float>, planeY: Float) -> SIMD3<Float>? {
        guard abs(d.y) > 1e-6 else { return nil }
        let t = (planeY - o.y) / d.y
        guard t > 0 else { return nil }
        return o + d * t
    }

    private static func vec(_ v: JSONValue?) -> SIMD3<Float>? {
        guard let a = v?.doubles, a.count >= 3 else { return nil }
        return SIMD3(Float(a[0]), Float(a[1]), Float(a[2]))
    }

    static func json(_ v: SIMD3<Float>) -> JSONValue {
        .array([v.x, v.y, v.z].map { .number((Double($0) * 10).rounded() / 10) })
    }

    /// Eye and target of a camera value, with the same defaults as `CameraState.make`.
    static func eyeTarget(
        _ camera: JSONValue?, width w: Float, height h: Float
    ) -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        let o = camera?.object ?? [:]
        let fov = Float(o["fov"]?.double ?? 40) * .pi / 180
        let target = vec(o["target"]) ?? SIMD3(w / 2, h / 2, 0)
        let eye = vec(o["position"]) ?? SIMD3(w / 2, h / 2, -(h / 2) / tan(fov / 2))
        return (eye, target)
    }

    /// Orbits `eye` around `target`: yaw about the vertical (y-down) axis, pitch clamped to ±85°.
    static func orbit(eye: SIMD3<Float>, target: SIMD3<Float>, yaw dyaw: Float, pitch dpitch: Float) -> SIMD3<Float> {
        let off = eye - target
        let r = simd_length(off)
        guard r > 1e-4 else { return eye }
        let yaw = atan2(off.x, off.z) + dyaw
        let lim: Float = 85 * .pi / 180
        let pitch = min(max(asin(max(-1, min(1, -off.y / r))) + dpitch, -lim), lim)
        return target + SIMD3(r * cos(pitch) * sin(yaw), -r * sin(pitch), r * cos(pitch) * cos(yaw))
    }

    /// Moves `eye` along the line to `target` by factor `k` (distance × k), never closer than `minDist`.
    static func dolly(eye: SIMD3<Float>, target: SIMD3<Float>, factor k: Float, minDist: Float = 10) -> SIMD3<Float> {
        let off = eye - target
        let r = simd_length(off)
        guard r > 1e-4 else { return eye }
        return target + off / r * max(minDist, r * k)
    }
}
