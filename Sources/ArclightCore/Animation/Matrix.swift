import Foundation
import simd

/// Matrix helpers (column-major, simd).
public enum M {
    public static func translate(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4; m.columns.3 = SIMD4(x, y, z, 1); return m
    }
    public static func scale(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(x, y, z, 1))
    }
    public static func rotateZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }
    public static func rotateY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
    }
    public static func rotateX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
    }
    /// Maps canvas pixels (0...w, 0...h, y down) to Metal clip space.
    public static func ortho(width w: Float, height h: Float) -> simd_float4x4 {
        simd_float4x4(SIMD4(2 / w, 0, 0, 0), SIMD4(0, -2 / h, 0, 0), SIMD4(0, 0, -1 / 20000, 0), SIMD4(-1, 1, 0.5, 1))
    }
    /// Largest axis scale of a transform, used to pick raster resolution for text/paths.
    public static func maxScale(_ m: simd_float4x4) -> Float {
        max(
            simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)))
    }
}
