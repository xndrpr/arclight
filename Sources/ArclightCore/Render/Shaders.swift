// Metal shader source, compiled at runtime with `makeLibrary(source:)`.
// Kept in Swift so the package needs no Xcode-only Metal build step.
// All colors are linear-light and premultiplied. Uniform structs use only
// float4 / float4x4 members so Swift and Metal layouts always match.
//
// Every draw writes two targets: color, and a signed circle-of-confusion ("coc", in canvas px,
// premultiplied by coverage) that the depth-of-field pass reads.

enum ShaderSource {
    /// The whole library: common definitions and 2D shapes/text, instanced 3D (Shaders+World.swift) and post
    /// effects (Shaders+Post.swift).
    static let main = [base, world, post].joined(separator: "\n\n")

    private static let base = """
        #include <metal_stdlib>
        using namespace metal;

        struct FrameU {
            float4 dof;       // blur px, focus distance, range, enabled
            float4 fogColor;  // linear
            float4 fog;       // near, far, enabled, 0
            float4 misc;
        };

        struct VOut { float4 pos [[position]]; float2 local; float2 uv; float vz; };
        struct IOut { float4 pos [[position]]; float2 uv; float vz; float4 color [[flat]]; float4 params [[flat]]; float4 extra [[flat]]; };
        struct FOut { float4 color [[color(0)]]; float4 coc [[color(1)]]; };

        static FOut finish(float4 c, float vz, constant FrameU& f) {
            if (f.fog.z > 0.5) {
                float k = smoothstep(f.fog.x, f.fog.y, vz);
                c.rgb = mix(c.rgb, f.fogColor.rgb * c.a, k);
            }
            float coc = 0;
            if (f.dof.w > 0.5) {
                float dz = vz - f.dof.y;
                coc = sign(dz) * f.dof.x * saturate(abs(dz) / max(f.dof.y * f.dof.z, 1e-3));
            }
            FOut o; o.color = c; o.coc = float4(coc * c.a, 0, 0, c.a);
            return o;
        }

        // ---- SDF shapes -------------------------------------------------------
        struct ShapeU {
            float4x4 mvp;
            float4 fill;
            float4 stroke;
            float4 geom;    // width, height, cornerRadius, strokeWidth
            float4 extra;   // kind (0 rect, 1 ellipse), aa padding (local units)
            float4 checker; // cell size (0 = off), offset x, offset y, 0  (local units)
            float4 checkerColor;
            float4 grad;    // linear: from.xy, to.xy | radial: centre.xy, radius, 0
            float4 gradInfo;// type (0 none, 1 linear, 2 radial), stop count
            float4 gStops;  // stop positions
            float4 gC0, gC1, gC2, gC3;
        };

        // Box-filtered checkerboard (no shimmer at grazing angles). Returns 0/1 coverage of the "on" cells.
        static float checkerAA(float2 q) {
            float2 w = max(fwidth(q), float2(1e-4));
            float2 i = 2.0 * (abs(fract((q - 0.5 * w) * 0.5) - 0.5) - abs(fract((q + 0.5 * w) * 0.5) - 0.5)) / w;
            return 0.5 - 0.5 * i.x * i.y;
        }

        static float4 gradientColor(constant ShapeU& u, float2 p) {
            float t;
            if (u.gradInfo.x < 1.5) {
                float2 d = u.grad.zw - u.grad.xy;
                t = dot(p - u.grad.xy, d) / max(dot(d, d), 1e-6);
            } else {
                t = length(p - u.grad.xy) / max(u.grad.z, 1e-6);
            }
            t = saturate(t);
            int n = int(u.gradInfo.y);
            float4 cs[4] = { u.gC0, u.gC1, u.gC2, u.gC3 };
            float ps[4] = { u.gStops.x, u.gStops.y, u.gStops.z, u.gStops.w };
            if (t <= ps[0]) return cs[0];
            for (int k = 1; k < n; k++) {
                if (t <= ps[k]) return mix(cs[k - 1], cs[k], (t - ps[k - 1]) / max(ps[k] - ps[k - 1], 1e-6));
            }
            return cs[n - 1];
        }

        vertex VOut shape_vs(uint vid [[vertex_id]], constant ShapeU& u [[buffer(0)]]) {
            float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
            float2 h = u.geom.xy * 0.5 + u.geom.w * 0.5 + u.extra.y;
            float2 p = c * h;
            VOut o;
            o.pos = u.mvp * float4(p, 0, 1);
            o.local = p;
            o.uv = c * 0.5 + 0.5;
            o.vz = o.pos.w;
            return o;
        }

        fragment FOut shape_fs(VOut in [[stage_in]], constant ShapeU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]]) {
            float2 h = max(u.geom.xy * 0.5, float2(1e-3));
            float2 p = in.local;
            float d;
            if (u.extra.x > 0.5) {
                float k0 = length(p / h);
                float k1 = length(p / (h * h));
                d = k1 > 0 ? k0 * (k0 - 1.0) / k1 : -min(h.x, h.y);
            } else {
                float r = min(u.geom.z, min(h.x, h.y));
                float2 q = abs(p) - h + r;
                d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
            }
            // Pixel footprint in local units. Derived from position, not from d: fwidth(d) is zero
            // for pixels straddling a sub-pixel-thin shape symmetrically, which made thin lines vanish.
            float aa = max(length(float2(length(dfdx(p)), length(dfdy(p)))) * 0.7071, 1e-4);
            float4 fill = u.gradInfo.x > 0.5 ? gradientColor(u, p) : u.fill;
            if (u.checker.x > 0) {
                float k = checkerAA((p + u.checker.yz) / u.checker.x);
                fill = u.checkerColor * k + fill * (1.0 - u.checkerColor.a * k);
            }
            float4 c = fill * saturate(0.5 - d / aa);
            float sw = u.geom.w;
            if (sw > 0 && u.stroke.a > 0) {
                float sc = saturate(0.5 - (abs(d) - sw * 0.5) / aa);
                c = u.stroke * sc + c * (1.0 - u.stroke.a * sc);
            }
            return finish(c, in.vz, f);
        }

        // ---- Textured quads (glyphs, images) ----------------------------------
        struct TexU {
            float4x4 mvp;   // projection * node world
            float4x4 unit;  // per-glyph/unit animation transform in node space
            float4 rect;    // x, y, w, h in node space (before unit transform)
            float4 color;   // premultiplied tint
            float4 clip;    // minX, minY, maxX, maxY in node space
            float4 mode;    // x: 0 = coverage mask (r8), 1 = straight-alpha rgba image
        };

        vertex VOut tex_vs(uint vid [[vertex_id]], constant TexU& u [[buffer(0)]]) {
            float2 uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
            float4 p = u.unit * float4(u.rect.xy + uv * u.rect.zw, 0, 1);
            VOut o;
            o.pos = u.mvp * p;
            o.local = p.xy;
            o.uv = uv;
            o.vz = o.pos.w;
            return o;
        }

        fragment FOut tex_fs(VOut in [[stage_in]], constant TexU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]],
                             texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            if (in.local.x < u.clip.x || in.local.y < u.clip.y || in.local.x > u.clip.z || in.local.y > u.clip.w) discard_fragment();
            float4 t = tex.sample(s, in.uv);
            float4 c = u.mode.x < 0.5 ? u.color * t.r : float4(t.rgb * t.a, t.a) * u.color.a;
            return finish(c, in.vz, f);
        }

        // Glyph coverage summed into one r16Float target (additive), so glyphs that touch leave no seam; union_fs
        // then tints it. u.color.a: the glyph's own alpha (reveal), without the layer opacity.
        fragment float4 cover_fs(VOut in [[stage_in]], constant TexU& u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            if (in.local.x < u.clip.x || in.local.y < u.clip.y || in.local.x > u.clip.z || in.local.y > u.clip.w) discard_fragment();
            return float4(tex.sample(s, in.uv).r * u.color.a, 0, 0, 0);
        }
        """
}
