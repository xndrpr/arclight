import Metal
import simd

public enum RenderError: Error, CustomStringConvertible {
    case noDevice, setup(String), readback
    public var description: String {
        switch self {
        case .noDevice: return "no Metal device"
        case .setup(let s): return "renderer setup failed: \(s)"
        case .readback: return "could not read rendered frame"
        }
    }
}

// GPU structs: each mirrors the Metal struct of the same name in Shaders.swift (U = uniforms, I = per-instance,
// V = vertex). Field order and sizes must match exactly; never reorder.

/// Rounded rect / ellipse / line, with optional checkerboard and gradient fill (`shape_fs`).
struct ShapeU {
    var mvp: simd_float4x4; var fill: SIMD4<Float>; var stroke: SIMD4<Float>; var geom: SIMD4<Float>;
    var extra: SIMD4<Float>
    var checker: SIMD4<Float> = .zero; var checkerColor: SIMD4<Float> = .zero
    var grad: SIMD4<Float> = .zero; var gradInfo: SIMD4<Float> = .zero; var gStops: SIMD4<Float> = .zero
    var gC0: SIMD4<Float> = .zero, gC1: SIMD4<Float> = .zero, gC2: SIMD4<Float> = .zero, gC3: SIMD4<Float> = .zero
}

struct ConeV { var pos: SIMD4<Float>; var color: SIMD4<Float> }
struct TexU {
    var mvp: simd_float4x4; var unit: simd_float4x4; var rect: SIMD4<Float>; var color: SIMD4<Float>;
    var clip: SIMD4<Float>; var mode: SIMD4<Float>
}
/// Per-pass world state. `misc` is unused but part of the shared layout.
struct FrameU {
    var dof: SIMD4<Float> = .zero; var fogColor: SIMD4<Float> = .zero; var fog: SIMD4<Float> = .zero;
    var misc: SIMD4<Float> = .zero
}
struct QuadI {
    var pos: SIMD4<Float>; var a: SIMD4<Float>; var b: SIMD4<Float>; var uv: SIMD4<Float>; var color: SIMD4<Float>
    var extra: SIMD4<Float> = .zero
}
struct PostU { var a: SIMD4<Float>; var b: SIMD4<Float>; var c: SIMD4<Float>; var d: SIMD4<Float> }

/// Offscreen buffers for one frame size.
public struct RenderTargets {
    public let width: Int, height: Int
    let hdrA: MTLTexture, hdrB: MTLTexture, coc: MTLTexture
    let bloom: [MTLTexture]
    /// Motion-blur accumulation buffer.
    let accum: MTLTexture
    /// Summed glyph coverage of one text layer whose glyphs touch (`coverFormat`).
    let cover: MTLTexture
}
