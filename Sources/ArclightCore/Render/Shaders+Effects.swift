// Metal source for per-layer effects (Renderer+Effects.swift): adjustments, gaussian blur, jump-flood outline,
// tint/offset for shadows and glows, masks and blend modes. All colours are linear, premultiplied.
// Part of `ShaderSource.main`; uses `FS` / `post_vs` from the post source.

extension ShaderSource {
    static let effects = """
        // ---- Layer effects -------------------------------------------------------
        static float3 fxUnpremul(float4 c) { return c.a > 1e-5 ? c.rgb / c.a : float3(0); }

        // p0: brightness, contrast, saturation, hue (radians); p1.x: temperature.
        struct FxAdjust { float4 p0; float4 p1; };
        fragment float4 fx_adjust_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                     constant FxAdjust& u [[buffer(0)]]) {
            float4 c = src.read(uint2(in.pos.xy));
            if (c.a <= 1e-5) return c;
            float3 rgb = fxUnpremul(c);
            rgb += u.p0.x;
            rgb = (rgb - 0.18) * u.p0.y + 0.18;  // contrast around linear mid-grey
            float l = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            rgb = mix(float3(l), rgb, u.p0.z);
            if (abs(u.p0.w) > 1e-4) {  // hue rotation about the grey axis
                float cs = cos(u.p0.w), sn = sin(u.p0.w);
                float3 k = float3(0.57735);
                rgb = rgb * cs + cross(k, rgb) * sn + k * dot(k, rgb) * (1.0 - cs);
            }
            rgb *= float3(1.0 + u.p1.x * 0.25, 1.0, 1.0 - u.p1.x * 0.25);
            return float4(max(rgb, 0.0) * c.a, c.a);
        }

        // Separable gaussian. p.xy: texel step (direction / size), p.z: sigma in px, p.w: tap stride in px.
        fragment float4 fx_blur_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
                                   constant float4& p [[buffer(0)]]) {
            float sigma = max(p.z, 0.5);
            int n = int(ceil(sigma * 3.0 / p.w));
            float4 acc = float4(0); float wsum = 0;
            for (int i = -n; i <= n; i++) {
                float x = float(i) * p.w;
                float w = exp(-x * x / (2.0 * sigma * sigma));
                acc += src.sample(s, in.uv + p.xy * x) * w;
                wsum += w;
            }
            return acc / wsum;
        }

        // The layer's alpha, moved by p.zw (texels) and tinted with the premultiplied colour c (shadow, glow).
        struct FxTint { float4 c; float4 p; };
        fragment float4 fx_tint_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
                                   constant FxTint& u [[buffer(0)]]) {
            return u.c * src.sample(s, in.uv - u.p.zw).a;
        }

        // Jump flood: seeds are pixels at least half covered; each pixel keeps the nearest seed seen so far.
        fragment float4 fx_jfa_init_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                       constant float4& p [[buffer(0)]]) {
            float a = src.read(uint2(in.pos.xy)).a;
            return a >= 0.5 ? float4(in.pos.xy, 0, 1) : float4(-1e6, -1e6, 0, 0);
        }
        fragment float4 fx_jfa_step_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                       constant float4& p [[buffer(0)]]) {
            int k = int(p.x);
            int2 size = int2(src.get_width(), src.get_height());
            int2 me = int2(in.pos.xy);
            float4 best = src.read(uint2(me));
            float bd = best.w > 0.5 ? distance(best.xy, in.pos.xy) : 1e9;
            for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                int2 q = me + int2(dx, dy) * k;
                if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) continue;
                float4 c = src.read(uint2(q));
                if (c.w < 0.5) continue;
                float d = distance(c.xy, in.pos.xy);
                if (d < bd) { bd = d; best = c; }
            }
            return best;
        }
        // Outline coverage from the distance to the nearest seed. c: premultiplied colour, p.x: width in px.
        struct FxOutline { float4 c; float4 p; };
        fragment float4 fx_outline_fs(FS in [[stage_in]], texture2d<float> jfa [[texture(0)]],
                                      constant FxOutline& u [[buffer(0)]]) {
            float4 s = jfa.read(uint2(in.pos.xy));
            if (s.w < 0.5) return float4(0);
            float d = distance(s.xy, in.pos.xy);
            return u.c * saturate(u.p.x - d + 0.5);
        }

        // A texture scaled by p.x, drawn with premultiplied (or additive) blending by the pipeline.
        fragment float4 fx_layer_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                    constant float4& p [[buffer(0)]]) {
            return src.read(uint2(in.pos.xy)) * p.x;
        }

        // src multiplied by a mask's alpha (p.x = 0) or luminance (p.x = 1); p.y = 1 inverts.
        fragment float4 fx_mask_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                   texture2d<float> mask [[texture(1)]], constant float4& p [[buffer(0)]]) {
            float4 m = mask.read(uint2(in.pos.xy));
            float k = p.x > 0.5 ? dot(fxUnpremul(m), float3(0.2126, 0.7152, 0.0722)) * m.a : m.a;
            k = p.y > 0.5 ? 1.0 - saturate(k) : saturate(k);
            return src.read(uint2(in.pos.xy)) * k;
        }

        // Blend modes on premultiplied colour: result = s·(1−da) + d·(1−sa) + sa·da·B(cs, cd).
        // p.x: 1 multiply, 2 screen, 3 overlay, 4 soft light, 5 add, 6 colour.
        static float3 fxSoft(float3 b, float3 s) {
            float3 d = select(sqrt(b), ((16.0 * b - 12.0) * b + 4.0) * b, b <= 0.25);
            return select(b + (2.0 * s - 1.0) * (d - b), b - (1.0 - 2.0 * s) * b * (1.0 - b), s <= 0.5);
        }
        // dst is the 2D overlay; world (the background and 3D layer under it) is blended against too, so a multiply
        // layer darkens the artboard background. The result goes back into the overlay where the layer covers.
        fragment float4 fx_blend_fs(FS in [[stage_in]], texture2d<float> ovT [[texture(0)]],
                                    texture2d<float> src [[texture(1)]], texture2d<float> world [[texture(2)]],
                                    constant float4& p [[buffer(0)]]) {
            float4 ov = ovT.read(uint2(in.pos.xy)), s = src.read(uint2(in.pos.xy));
            if (s.a <= 1e-5) return ov;
            float4 w = world.read(uint2(in.pos.xy));
            float4 d = ov + w * (1.0 - ov.a);
            int m = int(p.x + 0.5);
            float4 r;
            if (m == 5) { r = float4(d.rgb + s.rgb, saturate(d.a + s.a)); return ov * (1.0 - s.a) + r * s.a; }
            float3 cs = fxUnpremul(s), cd = fxUnpremul(d), b;
            if (m == 1) b = cs * cd;
            else if (m == 2) b = cs + cd - cs * cd;
            else if (m == 3) b = select(1.0 - 2.0 * (1.0 - cs) * (1.0 - cd), 2.0 * cs * cd, cd <= 0.5);
            else if (m == 4) b = fxSoft(cd, cs);
            else if (m == 6) {
                float3 w = float3(0.2126, 0.7152, 0.0722);
                b = cs + (dot(cd, w) - dot(cs, w));
            } else b = cs;
            float3 rgb = s.rgb * (1.0 - d.a) + d.rgb * (1.0 - s.a) + s.a * d.a * b;
            r = float4(rgb, s.a + d.a * (1.0 - s.a));
            // r already contains s's own coverage: make it opaque where s covers, keep the overlay elsewhere.
            float4 full = r.a > 1e-5 ? r / r.a : r;
            return ov * (1.0 - s.a) + full * s.a;
        }
        """
}
