import Foundation
import simd

/// A small glTF 2.0 reader: binary .glb (and .gltf with embedded or neighbouring buffers). It reads the default
/// scene's node tree, triangle primitives with POSITION, NORMAL and TEXCOORD_0, and each material's base colour
/// factor and texture. Skins (bones), morph targets (shape keys) and animation clips go into `Mesh.rig`, which
/// poses the vertices at any time; Draco- or meshopt-compressed files are refused with a clear message.
enum GLB {
    static func parse(_ data: Data) throws -> Mesh {
        guard data.count >= 20, data.u32(0) == 0x4654_6C67 else { throw MeshError.invalid("not a .glb file") }
        guard data.u32(4) == 2 else { throw MeshError.unsupported("only glTF 2.0 models are supported") }
        var json: Data?
        var bin: Data?
        var off = 12
        let total = min(Int(data.u32(8)), data.count)
        while off + 8 <= total {
            let len = Int(data.u32(off)), type = data.u32(off + 4)
            let start = off + 8
            guard len >= 0, start + len <= data.count else { throw MeshError.invalid("truncated chunk") }
            let chunk = data.subdata(in: start..<(start + len))
            if type == 0x4E4F_534A { json = chunk } else if type == 0x004E_4942 { bin = chunk }
            off = start + len
        }
        guard let json else { throw MeshError.invalid("no JSON chunk") }
        return try build(
            json: json,
            buffers: { i, uri in
                if i == 0 && uri == nil, let bin { return bin }
                return try external(uri, base: nil)
            })
    }

    static func parseGLTF(_ data: Data, base: URL) throws -> Mesh {
        try build(json: data, buffers: { _, uri in try external(uri, base: base) })
    }

    /// A buffer or image given by URI: a `data:` URI, or a file next to the .gltf.
    static func external(_ uri: String?, base: URL?) throws -> Data {
        guard let uri else { throw MeshError.invalid("buffer without data") }
        if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
            guard let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else {
                throw MeshError.invalid("bad data URI")
            }
            return d
        }
        guard let base, !uri.contains(".."), let name = uri.removingPercentEncoding else {
            throw MeshError.invalid("external buffer '\(uri)'")
        }
        return try Data(contentsOf: base.appendingPathComponent(name))
    }

    static func build(json: Data, buffers load: (Int, String?) throws -> Data) throws -> Mesh {
        let g: JSONValue
        do { g = try JSONDecoder().decode(JSONValue.self, from: json) } catch {
            throw MeshError.invalid("bad glTF JSON")
        }
        let required = (g["extensionsRequired"]?.array ?? []).compactMap(\.string)
        if let ext = required.first(where: { $0.contains("draco") || $0.contains("meshopt") }) {
            throw MeshError.unsupported("this model is compressed (\(ext)); export it without compression")
        }
        let bufferList = g["buffers"]?.array ?? []
        var buffers: [Data] = []
        for (i, b) in bufferList.enumerated() { buffers.append(try load(i, b["uri"]?.string)) }
        let views = g["bufferViews"]?.array ?? []
        let accessors = g["accessors"]?.array ?? []
        let meshes = g["meshes"]?.array ?? []
        let nodes = g["nodes"]?.array ?? []
        let materials = g["materials"]?.array ?? []
        let textures = g["textures"]?.array ?? []
        let images = g["images"]?.array ?? []

        func view(_ i: Int) throws -> (data: Data, offset: Int, length: Int, stride: Int?) {
            guard i >= 0, i < views.count else { throw MeshError.invalid("bufferView \(i)") }
            let v = views[i]
            let b = Int(v["buffer"]?.double ?? 0)
            guard b >= 0, b < buffers.count else { throw MeshError.invalid("buffer \(b)") }
            let off = Int(v["byteOffset"]?.double ?? 0), len = Int(v["byteLength"]?.double ?? 0)
            guard off >= 0, len >= 0, off + len <= buffers[b].count else { throw MeshError.invalid("bufferView range") }
            return (buffers[b], off, len, v["byteStride"]?.double.map(Int.init))
        }

        /// An accessor's values as floats, `n` components per element (integers normalised when flagged).
        func floats(_ i: Int) throws -> (values: [Float], comps: Int) {
            guard i >= 0, i < accessors.count else { throw MeshError.invalid("accessor \(i)") }
            let a = accessors[i]
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"]?.string ?? ""] ?? 0
            let count = Int(a["count"]?.double ?? 0)
            let ct = Int(a["componentType"]?.double ?? 0)
            let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][ct] ?? 0
            guard comps > 0, size > 0, count >= 0 else { throw MeshError.invalid("accessor \(i) type") }
            guard let vi = a["bufferView"]?.double else {
                return ([Float](repeating: 0, count: count * comps), comps)  // sparse-only / zero accessor
            }
            let v = try view(Int(vi))
            let stride = v.stride ?? comps * size
            let base = v.offset + Int(a["byteOffset"]?.double ?? 0)
            let norm = a["normalized"]?.bool ?? false
            guard count == 0 || base + (count - 1) * stride + comps * size <= v.offset + v.length else {
                throw MeshError.invalid("accessor \(i) out of range")
            }
            var out = [Float](repeating: 0, count: count * comps)
            v.data.withUnsafeBytes { raw in
                for e in 0..<count {
                    for c in 0..<comps {
                        let o = base + e * stride + c * size
                        let x: Float
                        switch ct {
                        case 5126: x = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                        case 5125: x = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        case 5123:
                            let u = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                            x = norm ? u / 65535 : u
                        case 5122:
                            let u = Float(raw.loadUnaligned(fromByteOffset: o, as: Int16.self))
                            x = norm ? max(u / 32767, -1) : u
                        case 5121:
                            let u = Float(raw.load(fromByteOffset: o, as: UInt8.self))
                            x = norm ? u / 255 : u
                        default:
                            let u = Float(raw.load(fromByteOffset: o, as: Int8.self))
                            x = norm ? max(u / 127, -1) : u
                        }
                        out[e * comps + c] = x
                    }
                }
            }
            return (out, comps)
        }

        func imageData(_ texIndex: Int) -> Data? {
            guard texIndex >= 0, texIndex < textures.count, let s = textures[texIndex]["source"]?.double,
                Int(s) >= 0, Int(s) < images.count
            else { return nil }
            let img = images[Int(s)]
            if let bv = img["bufferView"]?.double, let v = try? view(Int(bv)) {
                return v.data.subdata(in: v.offset..<(v.offset + v.length))
            }
            return img["uri"]?.string.flatMap { try? external($0, base: nil) }
        }

        func local(_ n: JSONValue) -> simd_float4x4 {
            if let m = n["matrix"]?.doubles, m.count == 16 {
                let f = m.map(Float.init)
                return simd_float4x4(
                    columns: (
                        SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                        SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])
                    ))
            }
            let t = n["translation"]?.doubles.map { $0.map(Float.init) } ?? [0, 0, 0]
            let r = n["rotation"]?.doubles.map { $0.map(Float.init) } ?? [0, 0, 0, 1]
            let s = n["scale"]?.doubles.map { $0.map(Float.init) } ?? [1, 1, 1]
            var m = matrix_identity_float4x4
            if r.count == 4 { m = simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])) }
            if s.count == 3 {
                m.columns.0 *= s[0]; m.columns.1 *= s[1]; m.columns.2 *= s[2]
            }
            if t.count == 3 { m.columns.3 = SIMD4(t[0], t[1], t[2], 1) }
            return m
        }

        var out = Mesh()
        // Skins, morph targets and clips: kept only when the file has any.
        let animations = g["animations"]?.array ?? []
        let skinList = g["skins"]?.array ?? []
        var pieces: [Rig.Piece] = []
        func vec3s(_ a: (values: [Float], comps: Int)?) -> [SIMD3<Float>] {
            guard let a, a.comps == 3 else { return [] }
            return stride(from: 0, to: a.values.count - 2, by: 3).map {
                SIMD3(a.values[$0], a.values[$0 + 1], a.values[$0 + 2])
            }
        }
        func vec4s(_ a: (values: [Float], comps: Int)?) -> [SIMD4<Float>] {
            guard let a, a.comps == 4 else { return [] }
            return stride(from: 0, to: a.values.count - 3, by: 4).map {
                SIMD4(a.values[$0], a.values[$0 + 1], a.values[$0 + 2], a.values[$0 + 3])
            }
        }
        func addMesh(_ mi: Int, world: simd_float4x4, node: Int = -1, skin: Int? = nil) throws {
            guard mi >= 0, mi < meshes.count else { return }
            let m = gltfToArclight * world
            let nm = simd_float3x3(
                SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            ).inverse.transpose
            // A mirroring transform turns faces inside out; swap the winding back.
            let flip = simd_determinant(world) < 0
            for p in meshes[mi]["primitives"]?.array ?? [] {
                guard Int(p["mode"]?.double ?? 4) == 4, let pi = p["attributes"]?["POSITION"]?.double else { continue }
                let pos = try floats(Int(pi))
                guard pos.comps == 3 else { continue }
                let count = pos.values.count / 3
                let nor = try p["attributes"]?["NORMAL"]?.double.map { try floats(Int($0)) }
                let tex = try p["attributes"]?["TEXCOORD_0"]?.double.map { try floats(Int($0)) }
                let base = UInt32(out.vertices.count)
                let targets = p["targets"]?.array ?? []
                if node >= 0, !animations.isEmpty || skin != nil || !targets.isEmpty {
                    var piece = Rig.Piece(
                        node: node, skin: skin, first: out.vertices.count, positions: vec3s(pos), normals: vec3s(nor))
                    if skin != nil {
                        let j = try p["attributes"]?["JOINTS_0"]?.double.map { try floats(Int($0)) }
                        let w = try p["attributes"]?["WEIGHTS_0"]?.double.map { try floats(Int($0)) }
                        piece.joints = vec4s(j).map { SIMD4<Int32>(Int32($0.x), Int32($0.y), Int32($0.z), Int32($0.w)) }
                        piece.weights = vec4s(w)
                        if piece.joints.count != count || piece.weights.count != count { piece.skin = nil }
                    }
                    for t in targets {
                        let tp = try t["POSITION"]?.double.map { try floats(Int($0)) }
                        let tn = try t["NORMAL"]?.double.map { try floats(Int($0)) }
                        var dp = vec3s(tp)
                        if dp.count != count { dp = [SIMD3<Float>](repeating: .zero, count: count) }
                        let dn = vec3s(tn)
                        piece.targets.append((dp, dn.count == count ? dn : nil))
                    }
                    if piece.normals.count != count { piece.normals = [SIMD3<Float>](repeating: .zero, count: count) }
                    pieces.append(piece)
                }
                for k in 0..<count {
                    let w = m * SIMD4(pos.values[k * 3], pos.values[k * 3 + 1], pos.values[k * 3 + 2], 1)
                    var n = SIMD3<Float>.zero
                    if let nor, nor.comps == 3, nor.values.count >= (k + 1) * 3 {
                        n = nm * SIMD3(nor.values[k * 3], nor.values[k * 3 + 1], nor.values[k * 3 + 2])
                        n = simd_length_squared(n) > 1e-20 ? simd_normalize(n) : .zero
                    }
                    var uv = SIMD2<Float>.zero
                    if let tex, tex.comps == 2, tex.values.count >= (k + 1) * 2 {
                        uv = SIMD2(tex.values[k * 2], tex.values[k * 2 + 1])
                    }
                    out.vertices.append(Mesh.Vertex(position: SIMD3(w.x, w.y, w.z), normal: n, uv: uv))
                }
                let start = out.indices.count
                var idx: [UInt32]
                if let ii = p["indices"]?.double {
                    idx = try floats(Int(ii)).values.map { UInt32(max($0, 0)) }
                } else {
                    idx = (0..<UInt32(count)).map { $0 }
                }
                idx = idx.filter { Int($0) < count }
                var t = 0
                while t + 2 < idx.count {
                    let (a, b, c) = (idx[t], idx[t + 1], idx[t + 2])
                    out.indices += flip ? [base + a, base + c, base + b] : [base + a, base + b, base + c]
                    t += 3
                }
                var color = SIMD4<Float>(1, 1, 1, 1)
                var texture: Data?
                if let mi = p["material"]?.double, Int(mi) >= 0, Int(mi) < materials.count {
                    let pbr = materials[Int(mi)]["pbrMetallicRoughness"]
                    if let f = pbr?["baseColorFactor"]?.doubles, f.count == 4 {
                        color = SIMD4(Float(f[0]), Float(f[1]), Float(f[2]), Float(f[3]))
                    }
                    if let ti = pbr?["baseColorTexture"]?["index"]?.double { texture = imageData(Int(ti)) }
                }
                if out.indices.count > start {
                    out.parts.append(
                        Mesh.Part(start: start, count: out.indices.count - start, color: color, texture: texture))
                }
            }
        }

        func walk(_ i: Int, parent: simd_float4x4, depth: Int) throws {
            guard i >= 0, i < nodes.count, depth < 64 else { return }
            let n = nodes[i]
            let w = parent * local(n)
            if let mi = n["mesh"]?.double {
                let sk = n["skin"]?.double.map(Int.init).flatMap { skinList.indices.contains($0) ? $0 : nil }
                try addMesh(Int(mi), world: w, node: i, skin: sk)
            }
            for c in n["children"]?.array ?? [] {
                if let ci = c.double { try walk(Int(ci), parent: w, depth: depth + 1) }
            }
        }

        let scenes = g["scenes"]?.array ?? []
        let si = Int(g["scene"]?.double ?? 0)
        if si >= 0, si < scenes.count, let roots = scenes[si]["nodes"]?.array {
            for r in roots { if let ri = r.double { try walk(Int(ri), parent: matrix_identity_float4x4, depth: 0) } }
        } else if !nodes.isEmpty {
            // No scene: every node that isn't someone's child is a root.
            let children = Set(nodes.flatMap { ($0["children"]?.array ?? []).compactMap { $0.double.map(Int.init) } })
            for i in nodes.indices where !children.contains(i) {
                try walk(i, parent: matrix_identity_float4x4, depth: 0)
            }
        } else {
            for i in meshes.indices { try addMesh(i, world: matrix_identity_float4x4) }
        }
        guard out.triangleCount > 0 else { throw MeshError.invalid("no triangles") }
        if !pieces.isEmpty {
            out.rig = try rig(
                g: g, pieces: pieces, skins: skinList, animations: animations, floats: floats, matrix: local)
            // Show the first frame of the first clip (or the rest pose) when nothing plays.
            if let r = out.rig {
                let posed = r.pose(clip: r.animated ? 0 : nil, time: 0)
                for k in out.vertices.indices where k < posed.positions.count {
                    out.vertices[k].position = posed.positions[k]
                    if simd_length_squared(posed.normals[k]) > 0 { out.vertices[k].normal = posed.normals[k] }
                }
            }
        }
        out.fillMissingNormals()
        return out
    }
}

extension GLB {
    /// The node tree at rest, the skins and the clips, for the pieces `build` placed.
    static func rig(
        g: JSONValue, pieces: [Rig.Piece], skins: [JSONValue], animations: [JSONValue],
        floats: (Int) throws -> (values: [Float], comps: Int), matrix: (JSONValue) -> simd_float4x4
    ) throws -> Rig {
        let nodes = g["nodes"]?.array ?? []
        let meshes = g["meshes"]?.array ?? []
        var rig = Rig()
        rig.nodes = nodes.map { n in
            var r = Rig.Node()
            if let m = n["matrix"]?.doubles, m.count == 16 { r.matrix = matrix(n) }
            if let t = n["translation"]?.doubles, t.count == 3 { r.t = SIMD3(Float(t[0]), Float(t[1]), Float(t[2])) }
            if let q = n["rotation"]?.doubles, q.count == 4 {
                r.r = simd_quatf(ix: Float(q[0]), iy: Float(q[1]), iz: Float(q[2]), r: Float(q[3]))
            }
            if let s = n["scale"]?.doubles, s.count == 3 { r.s = SIMD3(Float(s[0]), Float(s[1]), Float(s[2])) }
            let mw = n["mesh"]?.double.map(Int.init).flatMap { meshes.indices.contains($0) ? meshes[$0] : nil }
            r.weights = (n["weights"]?.doubles ?? mw?["weights"]?.doubles ?? []).map(Float.init)
            return r
        }
        for (i, n) in nodes.enumerated() {
            for c in n["children"]?.array ?? [] {
                if let ci = c.double.map(Int.init), ci >= 0, ci < rig.nodes.count, ci != i { rig.nodes[ci].parent = i }
            }
        }
        // Morph weights default to zero for every target the node's pieces have.
        for p in pieces where p.node < rig.nodes.count && rig.nodes[p.node].weights.count < p.targets.count {
            rig.nodes[p.node].weights += [Float](repeating: 0, count: p.targets.count - rig.nodes[p.node].weights.count)
        }
        rig.skins = try skins.map { s in
            let joints = (s["joints"]?.array ?? []).compactMap { $0.double.map(Int.init) }
            var inv: [simd_float4x4] = []
            if let a = s["inverseBindMatrices"]?.double {
                let f = try floats(Int(a))
                if f.comps == 16 {
                    inv = stride(from: 0, to: f.values.count - 15, by: 16).map { o in
                        simd_float4x4(
                            columns: (
                                SIMD4(f.values[o], f.values[o + 1], f.values[o + 2], f.values[o + 3]),
                                SIMD4(f.values[o + 4], f.values[o + 5], f.values[o + 6], f.values[o + 7]),
                                SIMD4(f.values[o + 8], f.values[o + 9], f.values[o + 10], f.values[o + 11]),
                                SIMD4(f.values[o + 12], f.values[o + 13], f.values[o + 14], f.values[o + 15])
                            ))
                    }
                }
            }
            return Rig.Skin(joints: joints, inverseBind: inv)
        }
        rig.pieces = pieces
        for (ai, a) in animations.enumerated() {
            let samplers = a["samplers"]?.array ?? []
            var channels: [Rig.Channel] = []
            var duration: Float = 0
            for c in a["channels"]?.array ?? [] {
                guard let node = c["target"]?["node"]?.double.map(Int.init), node >= 0, node < rig.nodes.count,
                    let si = c["sampler"]?.double.map(Int.init), samplers.indices.contains(si),
                    let inA = samplers[si]["input"]?.double, let outA = samplers[si]["output"]?.double
                else { continue }
                let path: Rig.Path
                switch c["target"]?["path"]?.string {
                case "translation": path = .translation
                case "rotation": path = .rotation
                case "scale": path = .scale
                case "weights": path = .weights
                default: continue  // "pointer" and other extensions
                }
                let interp: Rig.Interpolation =
                    ["STEP": .step, "CUBICSPLINE": .cubic][samplers[si]["interpolation"]?.string ?? ""] ?? .linear
                let times = try floats(Int(inA)).values
                let out = try floats(Int(outA))
                guard !times.isEmpty else { continue }
                // Weights: one value per target per key, packed as a scalar list.
                let perKey = out.values.count / max(times.count * (interp == .cubic ? 3 : 1), 1)
                let comps = path == .weights ? perKey : out.comps
                guard comps > 0 else { continue }
                channels.append(
                    Rig.Channel(
                        node: node, path: path, times: times, values: out.values, comps: comps, interpolation: interp))
                duration = max(duration, times.last ?? 0)
            }
            let name = a["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "clip \(ai)"
            rig.clips.append(Rig.Clip(name: name, channels: channels, duration: duration))
        }
        return rig
    }
}

extension Data {
    func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    }
}
