// Metal source for depth-correct 3D layers: the depth step drawn after each 3D card. Part of `ShaderSource.main`,
// appended after the recorded base, world and post parts (it adds functions and changes none of theirs).

extension ShaderSource {
    static let space = """
        // ---- Depth for 3D cards ------------------------------------------------
        // Each 3D card is drawn in list order (colour, depth tested), then again into depth only: where it is at
        // least half covered it writes its depth, pushed back by FrameU.misc.z (a fraction of the view depth) so
        // layers stacked on the same plane still draw over it in list order.
        // FrameU.misc: x = far/(far-near), y = near*far/(far-near) (view depth -> window depth), z = push.
        struct DOut { float depth [[depth(any)]]; };

        static DOut pushedDepth(float vz, constant FrameU& f) {
            DOut o;
            float v = max(vz * (1.0 + f.misc.z), 1e-4);
            o.depth = saturate(f.misc.x - f.misc.y / v);
            return o;
        }

        fragment DOut tex_depth_fs(VOut in [[stage_in]], constant TexU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]],
                                   texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            if (in.local.x < u.clip.x || in.local.y < u.clip.y || in.local.x > u.clip.z || in.local.y > u.clip.w) discard_fragment();
            float4 t = tex.sample(s, in.uv);
            float a = u.mode.x < 0.5 ? u.color.a * t.r : t.a * u.color.a;
            if (a < 0.5) discard_fragment();
            return pushedDepth(in.vz, f);
        }

        // A box face: an image (or 1x1 white for a colour) repeated mode.yz times across the face and tinted by
        // u.color (premultiplied, shading included). Gradients are taken before fract so tiles have no seams.
        fragment FOut box_tex_fs(VOut in [[stage_in]], constant TexU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]],
                                 texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            float2 t = in.uv * max(u.mode.yz, float2(1e-3));
            float4 c = tex.sample(s, fract(t), gradient2d(dfdx(t), dfdy(t)));
            c = float4(c.rgb * c.a, c.a) * u.color;
            return finish(c, in.vz, f);
        }

        // A relief image: a cols x rows grid over the picture's rect (TexU.mode.y, .z), each vertex pushed towards
        // the camera (local -z) by the depth map (white = near) times mode.w px. Six vertices per cell.
        vertex VOut relief_vs(uint vid [[vertex_id]], constant TexU& u [[buffer(0)]],
                              texture2d<float> depth [[texture(0)]], sampler s [[sampler(0)]]) {
            uint cols = uint(max(u.mode.y, 1.0)), rows = uint(max(u.mode.z, 1.0));
            uint cell = vid / 6, k = vid % 6;
            uint cx = cell % cols, cy = cell / cols;
            // Two triangles: (0,0) (1,0) (0,1) and (1,0) (1,1) (0,1).
            const uint2 corner[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };
            float2 uv = float2(float(cx + corner[k].x) / float(cols), float(cy + corner[k].y) / float(rows));
            float d = depth.sample(s, uv, level(0)).r;
            float4 p = u.unit * float4(u.rect.xy + uv * u.rect.zw, -d * u.mode.w, 1);
            VOut o;
            o.pos = u.mvp * p;
            o.local = p.xy;
            o.uv = uv;
            o.vz = o.pos.w;
            return o;
        }

        // ---- Models -------------------------------------------------------------
        struct MeshV { float4 pos; float4 normal; float4 uv; };
        struct MeshU {
            float4x4 mvp;
            float4x4 world;
            float4 color;   // premultiplied tint
            float4 light;   // direction towards the light (world), w: textured
            float4 eye;     // camera position (world), w: material (0 matte, 1 glossy, 2 clay)
            float4 params;  // shade, rim
        };
        struct MOut { float4 pos [[position]]; float3 n; float3 wpos; float2 uv; float vz; };

        vertex MOut mesh_vs(uint vid [[vertex_id]], constant MeshU& u [[buffer(0)]],
                            const device MeshV* v [[buffer(1)]]) {
            MeshV x = v[vid];
            MOut o;
            o.pos = u.mvp * float4(x.pos.xyz, 1);
            o.wpos = (u.world * float4(x.pos.xyz, 1)).xyz;
            o.n = (u.world * float4(x.normal.xyz, 0)).xyz;
            o.uv = x.uv.xy;
            o.vz = o.pos.w;
            return o;
        }

        fragment FOut mesh_fs(MOut in [[stage_in]], constant MeshU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]],
                              texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            float4 base = u.color;
            if (u.light.w > 0.5) {
                float4 t = tex.sample(s, in.uv);
                base = float4(t.rgb * t.a, t.a) * u.color;
            }
            float3 V = normalize(u.eye.xyz - in.wpos);
            float3 N = length(in.n) > 1e-6 ? normalize(in.n) : V;
            if (dot(N, V) < 0) N = -N;  // two-sided
            float3 L = normalize(u.light.xyz);
            float diff = saturate((dot(N, L) + 0.35) / 1.35);  // wrapped, soft terminator
            float shade = u.params.x;
            float3 c = base.rgb * ((1.0 - shade) + shade * diff);
            float m = u.eye.w;
            if (m > 0.5 && m < 1.5) {
                float spec = pow(saturate(dot(N, normalize(L + V))), 40.0);
                c += spec * 0.45 * base.a;
            }
            float rim = u.params.y + (m > 1.5 ? 0.35 : 0.0);
            if (rim > 0) c += pow(1.0 - saturate(dot(N, V)), 3.0) * rim * base.a * 0.6;
            return finish(float4(c, base.a), in.vz, f);
        }

        fragment DOut shape_depth_fs(VOut in [[stage_in]], constant ShapeU& u [[buffer(0)]], constant FrameU& f [[buffer(1)]]) {
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
            float aa = max(length(float2(length(dfdx(p)), length(dfdy(p)))) * 0.7071, 1e-4);
            float fa = u.gradInfo.x > 0.5 ? gradientColor(u, p).a : u.fill.a;
            float a = fa * saturate(0.5 - d / aa);
            float sw = u.geom.w;
            if (sw > 0 && u.stroke.a > 0) a = max(a, u.stroke.a * saturate(0.5 - (abs(d) - sw * 0.5) / aa));
            if (a < 0.5) discard_fragment();
            return pushedDepth(in.vz, f);
        }
        """
}
