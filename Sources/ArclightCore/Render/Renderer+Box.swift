import Foundation
import Metal
import simd

extension Renderer {
    /// One face of a box in its local space (centred on 0, y down): where it is, which way it faces (outwards), and
    /// the axes its picture runs along as seen from the side it's meant to be looked at.
    struct BoxFace: Equatable {
        let name: String
        let center: SIMD3<Float>
        /// Outward normal.
        let normal: SIMD3<Float>
        /// The picture's x (right) and y (down) directions.
        let right: SIMD3<Float>, down: SIMD3<Float>
        let size: SIMD2<Float>

        /// Face → box local: a quad in the face's xy plane centred on 0 lands on the face.
        var matrix: simd_float4x4 {
            simd_float4x4(columns: (SIMD4(right, 0), SIMD4(down, 0), SIMD4(normal, 0), SIMD4(center, 1)))
        }
    }

    /// The six faces of a box `s` = (w, h, d). Outside, each picture reads upright from outside; `inside` (a room),
    /// from inside: walls upright, the floor with its top towards the back wall.
    static func boxFaces(_ s: SIMD3<Float>, inside: Bool) -> [BoxFace] {
        let (w, h, d) = (s.x, s.y, s.z)
        let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
        // (name, outward normal, right seen from outside, down, size)
        let faces: [(String, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD2<Float>)] = [
            ("front", -z, x, y, SIMD2(w, h)),
            ("back", z, -x, y, SIMD2(w, h)),
            ("left", -x, -z, y, SIMD2(d, h)),
            ("right", x, z, y, SIMD2(d, h)),
            ("top", -y, x, -z, SIMD2(w, d)),
            ("bottom", y, -x, -z, SIMD2(w, d)),
        ]
        return faces.map { name, n, r, dn, size in
            let half = SIMD3(w, h, d) / 2
            return BoxFace(
                name: name, center: n * half, normal: n, right: inside ? -r : r, down: dn, size: size)
        }
    }

    /// A box layer: each face the camera can see (outer faces, or inner ones with `inside`) as a card, with
    /// simple directional shading. Called once per world stage by `drawCard`.
    func drawBox(_ n: EvalNode, cam: CameraState, assets: URL?, enc: MTLRenderCommandEncoder) {
        let sz = n.props["size"]?.doubles ?? [400, 400, 400]
        guard sz.count >= 3 else { return }
        let size = SIMD3(Float(sz[0]), Float(sz[1]), Float(sz[2]))
        guard size.x > 0, size.y > 0, size.z > 0 else { return }
        let inside = n.bool("inside", false)
        let base = n.color("color") ?? foreground
        let shade = Float(min(max(n.num("shade", 0.3), 0), 1))
        let l = n.props["light"]?.doubles ?? [-0.4, -1, -0.6]
        var toLight = l.count >= 3 ? SIMD3(Float(l[0]), Float(l[1]), Float(l[2])) : SIMD3(-0.4, -1, -0.6)
        toLight = simd_length(toLight) > 1e-6 ? simd_normalize(toLight) : SIMD3(0, -1, 0)

        enc.setRenderPipelineState(boxPipeline)
        for f in Renderer.boxFaces(size, inside: inside) {
            let spec = n.props[f.name]
            if spec?.bool == false { continue }
            let world = n.world * f.matrix
            let c = world.columns.3
            let centerW = SIMD3(c.x, c.y, c.z)
            let nw = world.columns.2
            var normalW = SIMD3(nw.x, nw.y, nw.z)
            normalW = simd_length(normalW) > 1e-9 ? simd_normalize(normalW) : normalW
            // The side that faces the camera: outward faces from outside, inward ones from inside.
            let facing = simd_dot(normalW, cam.position - centerW)
            if inside ? facing >= 0 : facing <= 0 { continue }
            let lit = simd_dot(inside ? -normalW : normalW, toLight)
            let b = Double(1 - shade + shade * min(max(0.5 + 0.5 * lit, 0), 1))
            let src = spec?["src"]?.string
            // An image shows its own colours unless the face gives a tint; a plain face takes the box colour.
            let col = RGBA.parse(spec?["color"]) ?? (src == nil ? base : RGBA(1, 1, 1))
            var lin = col.linearPremultiplied(opacity: n.opacity)
            lin.x *= Float(b); lin.y *= Float(b); lin.z *= Float(b)
            let tex = src.flatMap { texture(src: $0, assets: assets) } ?? whiteTexture
            let tile = spec?["tile"]?.doubles ?? [1, 1]
            var u = TexU(
                mvp: cam.viewProj * world, unit: matrix_identity_float4x4,
                rect: SIMD4(-f.size.x / 2, -f.size.y / 2, f.size.x, f.size.y), color: lin, clip: TexU.noClip,
                mode: SIMD4(1, Float(tile.first ?? 1), Float(tile.count > 1 ? tile[1] : tile.first ?? 1), 0))
            drawTexturedQuad(&u, texture: tex, enc: enc)
        }
    }
}
