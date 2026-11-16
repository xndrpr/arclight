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
