import Foundation
import ModelIO
import simd

/// A static triangle mesh in Arclight's space (x right, y down, z into the screen), ready to upload: one vertex
/// list, one index list, and parts that each draw a range of indices with one material.
public struct Mesh: Sendable {
    public struct Vertex: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var normal: SIMD3<Float>
        public var uv: SIMD2<Float>
    }

    public struct Part: Sendable {
        /// First index and number of indices (a multiple of 3).
        public var start: Int, count: Int
        /// Base colour (linear, straight alpha), multiplied with the texture when there is one.
        public var color: SIMD4<Float>
        /// Encoded PNG/JPEG of the base colour texture.
        public var texture: Data?
    }

    public var vertices: [Vertex] = []
    public var indices: [UInt32] = []
    public var parts: [Part] = []

    public var triangleCount: Int { indices.count / 3 }

    /// Axis-aligned bounds of all vertices (zero box when empty).
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = vertices.first?.position else { return (.zero, .zero) }
        var lo = first, hi = first
        for v in vertices { lo = simd_min(lo, v.position); hi = simd_max(hi, v.position) }
        return (lo, hi)
    }

    /// Loads a .glb/.gltf (own parser) or anything ModelIO reads (.obj, .usdz, .usd, .ply, .stl, .abc).
    public static func load(_ url: URL) throws -> Mesh {
        switch url.pathExtension.lowercased() {
        case "glb": return try GLB.parse(try Data(contentsOf: url))
        case "gltf": return try GLB.parseGLTF(try Data(contentsOf: url), base: url.deletingLastPathComponent())
        default: return try ModelIOLoader.load(url)
        }
    }

    /// File extensions `load` understands.
    public static let extensions: Set<String> = [
        "glb", "gltf", "obj", "usdz", "usd", "usda", "usdc", "ply", "stl", "abc",
    ]

    /// Fills in smooth normals for vertices that have none (zero length), from the triangles around them.
    mutating func fillMissingNormals() {
        guard vertices.contains(where: { simd_length_squared($0.normal) < 1e-12 }) else { return }
        var acc = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            let n = simd_cross(
                vertices[b].position - vertices[a].position, vertices[c].position - vertices[a].position)
            acc[a] += n; acc[b] += n; acc[c] += n
        }
        for k in vertices.indices where simd_length_squared(vertices[k].normal) < 1e-12 {
            let n = acc[k]
            vertices[k].normal = simd_length_squared(n) > 1e-20 ? simd_normalize(n) : SIMD3(0, 0, -1)
        }
    }
}

public enum MeshError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "not a readable 3D model: \(s)"
        case .unsupported(let s): return s
        }
    }
}

/// glTF uses y up and z towards the viewer; Arclight y down and z into the screen. Turning half a turn about x
/// maps one onto the other (and keeps faces and handedness).
let gltfToArclight = simd_float4x4(diagonal: SIMD4(1, -1, -1, 1))

/// Reads meshes ModelIO understands (OBJ, USD/USDZ, PLY, STL, Alembic) into a `Mesh`.
enum ModelIOLoader {
    static func load(_ url: URL) throws -> Mesh {
        let vd = MDLVertexDescriptor()
        vd.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        vd.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        vd.attributes[2] = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        vd.layouts[0] = MDLVertexBufferLayout(stride: 32)
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { throw MeshError.invalid("no meshes in \(url.lastPathComponent)") }
        var out = Mesh()
        for m in meshes {
            if m.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                m.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
            m.vertexDescriptor = vd
            let world = gltfToArclight * (m.transform?.matrix ?? matrix_identity_float4x4)
            let normalM = simd_float3x3(
                SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
            ).inverse.transpose
            let base = UInt32(out.vertices.count)
            let buf = m.vertexBuffers[0].map()
            for k in 0..<m.vertexCount {
                let p = buf.bytes.advanced(by: k * 32)
                let f = p.assumingMemoryBound(to: Float.self)
                let pos = world * SIMD4(f[0], f[1], f[2], 1)
                var n = normalM * SIMD3(f[3], f[4], f[5])
                n = simd_length_squared(n) > 1e-20 ? simd_normalize(n) : .zero
                out.vertices.append(Mesh.Vertex(position: SIMD3(pos.x, pos.y, pos.z), normal: n, uv: SIMD2(f[6], f[7])))
            }
            for case let sub as MDLSubmesh in m.submeshes ?? [] {
                guard sub.geometryType == .triangles else { continue }
                let ib = sub.indexBuffer.map()
                let start = out.indices.count
                for k in 0..<sub.indexCount {
                    let idx: UInt32
                    switch sub.indexType {
                    case .uInt8: idx = UInt32(ib.bytes.load(fromByteOffset: k, as: UInt8.self))
                    case .uInt16: idx = UInt32(ib.bytes.load(fromByteOffset: k * 2, as: UInt16.self))
                    default: idx = ib.bytes.load(fromByteOffset: k * 4, as: UInt32.self)
                    }
                    out.indices.append(base + idx)
                }
                var color = SIMD4<Float>(0.8, 0.8, 0.8, 1)
                if let prop = sub.material?.property(with: .baseColor), prop.type == .float3 {
                    color = SIMD4(prop.float3Value, 1)
                } else if let prop = sub.material?.property(with: .baseColor), prop.type == .float4 {
                    color = prop.float4Value
                }
                out.parts.append(Mesh.Part(start: start, count: out.indices.count - start, color: color, texture: nil))
            }
        }
        guard out.triangleCount > 0 else { throw MeshError.invalid("no triangles in \(url.lastPathComponent)") }
        out.fillMissingNormals()
        return out
    }
}
