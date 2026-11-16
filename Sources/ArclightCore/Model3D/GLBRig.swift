import Foundation
import simd

/// What a glTF needs to move: its node tree at rest, skins (bones), morph targets (shape keys) and animation
/// clips. `pose` evaluates a clip at a time and returns every vertex moved, in Arclight space, in the same order as
/// `Mesh.vertices`; the triangles and materials stay the same.
public struct Rig: Sendable {
    struct Node: Sendable {
        var parent: Int = -1
        var t = SIMD3<Float>(0, 0, 0)
        var r = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var s = SIMD3<Float>(1, 1, 1)
        /// A node given as a matrix can't be animated (glTF rule); it keeps this.
        var matrix: simd_float4x4?
        /// Morph weights at rest (the node's, else its mesh's).
        var weights: [Float] = []
    }

    struct Skin: Sendable {
        var joints: [Int]
        var inverseBind: [simd_float4x4]
    }

    /// One placed primitive: a range of `Mesh.vertices` with its rest data in the mesh's own space.
    struct Piece: Sendable {
        var node: Int
        var skin: Int?
        var first: Int
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var joints: [SIMD4<Int32>] = []
        var weights: [SIMD4<Float>] = []
        /// Morph targets: position (and normal) offsets per vertex.
        var targets: [(positions: [SIMD3<Float>], normals: [SIMD3<Float>]?)] = []
    }

    enum Path: Sendable { case translation, rotation, scale, weights }
    enum Interpolation: Sendable { case linear, step, cubic }

    struct Channel: Sendable {
        var node: Int
        var path: Path
        var times: [Float]
        /// Values per key (`comps` floats each; three times as many for cubic: in-tangent, value, out-tangent).
        var values: [Float]
        var comps: Int
        var interpolation: Interpolation
    }

    public struct Clip: Sendable {
        public var name: String
        var channels: [Channel]
        public var duration: Float
    }

    var nodes: [Node] = []
    var skins: [Skin] = []
    var pieces: [Piece] = []
    public internal(set) var clips: [Clip] = []

    /// True when there is anything to play.
    public var animated: Bool { clips.contains { $0.duration > 0 && !$0.channels.isEmpty } }

    /// The clip a layer's `clip` names: an index ("0"), a name (any case), or empty for the first one.
    /// nil for "none" or a name that isn't there.
    public func clipIndex(_ name: String) -> Int? {
        let s = name.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "auto" { return clips.isEmpty ? nil : 0 }
        if s.lowercased() == "none" { return nil }
        if let i = Int(s), clips.indices.contains(i) { return i }
        return clips.firstIndex { $0.name.lowercased() == s.lowercased() }
    }

    /// Every vertex position and normal (Arclight space) with clip `clip` at `time` seconds (nil: rest pose).
    public func pose(clip: Int?, time: Float) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        var local = nodes
        if let clip, clips.indices.contains(clip) {
            for ch in clips[clip].channels where local.indices.contains(ch.node) {
                let v = Self.sample(ch, at: time)
                switch ch.path {
                case .translation where v.count >= 3: local[ch.node].t = SIMD3(v[0], v[1], v[2])
                case .scale where v.count >= 3: local[ch.node].s = SIMD3(v[0], v[1], v[2])
                case .rotation where v.count >= 4:
                    let q = simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3])
                    local[ch.node].r = simd_length(q.vector) > 1e-8 ? simd_normalize(q) : local[ch.node].r
                case .weights: local[ch.node].weights = v
                default: break
                }
            }
        }
        // World matrices, parents first (memoised; a cycle stops at the depth limit).
        var world = [simd_float4x4?](repeating: nil, count: local.count)
        func matrix(_ i: Int, depth: Int = 0) -> simd_float4x4 {
            if let w = world[i] { return w }
            let n = local[i]
            let m: simd_float4x4
            if let fixed = n.matrix {
                m = fixed
            } else {
                var r = simd_float4x4(n.r)
                r.columns.0 *= n.s.x; r.columns.1 *= n.s.y; r.columns.2 *= n.s.z
                r.columns.3 = SIMD4(n.t, 1)
                m = r
            }
            let w = n.parent >= 0 && n.parent < local.count && depth < 64 ? matrix(n.parent, depth: depth + 1) * m : m
            world[i] = w
            return w
        }

        let total = pieces.map { $0.first + $0.positions.count }.max() ?? 0
        var pos = [SIMD3<Float>](repeating: .zero, count: total)
        var nor = [SIMD3<Float>](repeating: .zero, count: total)
        for p in pieces {
            let weights = p.node < local.count ? local[p.node].weights : []
            // Joint matrices for this skin, once per piece.
            var jointM: [simd_float4x4] = []
            if let si = p.skin, skins.indices.contains(si) {
                let sk = skins[si]
                jointM = sk.joints.enumerated().map { k, j in
                    let jw = j >= 0 && j < local.count ? matrix(j) : matrix_identity_float4x4
                    return jw * (k < sk.inverseBind.count ? sk.inverseBind[k] : matrix_identity_float4x4)
                }
            }
            let nodeM = p.node < local.count ? matrix(p.node) : matrix_identity_float4x4
            for k in p.positions.indices {
                var v = p.positions[k]
                var n = k < p.normals.count ? p.normals[k] : .zero
                for (ti, t) in p.targets.enumerated() where ti < weights.count && weights[ti] != 0 {
                    let w = weights[ti]
                    if k < t.positions.count { v += w * t.positions[k] }
                    if let tn = t.normals, k < tn.count { n += w * tn[k] }
                }
                var m = nodeM
                if !jointM.isEmpty, k < p.joints.count, k < p.weights.count {
                    // Skinned: the node's own transform is ignored (glTF); the bones carry the mesh.
                    let j = p.joints[k], w = p.weights[k]
                    var s = simd_float4x4()
                    var sum: Float = 0
                    for c in 0..<4 where w[c] > 0 {
                        let ji = Int(j[c])
                        guard ji >= 0, ji < jointM.count else { continue }
                        let jm = jointM[ji]
                        s.columns.0 += jm.columns.0 * w[c]; s.columns.1 += jm.columns.1 * w[c]
                        s.columns.2 += jm.columns.2 * w[c]; s.columns.3 += jm.columns.3 * w[c]
                        sum += w[c]
                    }
                    if sum > 1e-6 { m = s * (1 / sum) }
                }
                m = gltfToArclight * m
                let wp = m * SIMD4(v, 1)
                pos[p.first + k] = SIMD3(wp.x, wp.y, wp.z)
                let nm = simd_float3x3(
                    SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                    SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                    SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
                // Inverse transpose keeps normals right under uneven scale; a degenerate matrix falls back to itself.
                let nt = abs(nm.determinant) > 1e-12 ? nm.inverse.transpose : nm
                let wn = nt * n
                nor[p.first + k] = simd_length_squared(wn) > 1e-20 ? simd_normalize(wn) : .zero
            }
        }
        return (pos, nor)
    }

    /// A channel's value at `time` (clamped to its keys).
    static func sample(_ ch: Channel, at time: Float) -> [Float] {
        let n = ch.times.count, c = ch.comps
        guard n > 0, c > 0 else { return [] }
        let cubic = ch.interpolation == .cubic
        func value(_ k: Int) -> [Float] {
            let o = cubic ? (k * 3 + 1) * c : k * c
            guard o + c <= ch.values.count else { return [Float](repeating: 0, count: c) }
            return Array(ch.values[o..<(o + c)])
        }
        if n == 1 || time <= ch.times[0] { return value(0) }
        if time >= ch.times[n - 1] { return value(n - 1) }
        // The key before `time` (binary search).
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if ch.times[mid] <= time { lo = mid } else { hi = mid }
        }
        let t0 = ch.times[lo], t1 = ch.times[hi]
        let dt = max(t1 - t0, 1e-9)
        let u = min(max((time - t0) / dt, 0), 1)
        switch ch.interpolation {
        case .step:
            return value(lo)
        case .linear:
            let a = value(lo), b = value(hi)
            if ch.path == .rotation, c == 4 {
                let qa = simd_quatf(ix: a[0], iy: a[1], iz: a[2], r: a[3])
                let qb = simd_quatf(ix: b[0], iy: b[1], iz: b[2], r: b[3])
                let q = simd_slerp(qa, qb, u)
                return [q.imag.x, q.imag.y, q.imag.z, q.real]
            }
            return zip(a, b).map { $0 + ($1 - $0) * u }
        case .cubic:
            // Hermite spline: value and tangents per key, tangents scaled by the key gap.
            func at(_ k: Int, _ part: Int) -> [Float] {
                let o = (k * 3 + part) * c
                guard o + c <= ch.values.count else { return [Float](repeating: 0, count: c) }
                return Array(ch.values[o..<(o + c)])
            }
            let p0 = at(lo, 1), m0 = at(lo, 2), p1 = at(hi, 1), m1 = at(hi, 0)
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            var out = [Float](repeating: 0, count: c)
            for i in 0..<c {
                let a: Float = h00 * p0[i] + h01 * p1[i]
                let b: Float = h10 * dt * m0[i] + h11 * dt * m1[i]
                out[i] = a + b
            }
            if ch.path == .rotation, c == 4 {
                let l = sqrt(out.reduce(0) { $0 + $1 * $1 })
                if l > 1e-8 { out = out.map { $0 / l } }
            }
            return out
        }
    }
}
