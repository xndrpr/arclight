// Metal source for the post passes: copy, motion-blur accumulation, depth of field, bloom and the final grade.
// Part of `ShaderSource.main`.

extension ShaderSource {
    static let post = """
        // ---- Post ---------------------------------------------------------------
        struct FS { float4 pos [[position]]; float2 uv; };

        vertex FS post_vs(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            FS o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
        }

        // Filtered copy (draft preview upscale).
        fragment float4 copy_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
                                constant float4& p [[buffer(0)]]) {
            return src.sample(s, in.uv);
        }

        // Weighted copy, blended additively: motion-blur accumulation.
        fragment float4 scale_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], constant float4& p [[buffer(0)]]) {
            return src.read(uint2(in.pos.xy)) * p.x;
        }

        // Scatter-as-gather bokeh on a golden-angle disc. coc is signed: < 0 in front of focus.
        // Far samples never spread further than the centre's own blur, so sharp foreground keeps clean edges.
        fragment float4 dof_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> cocT [[texture(1)]],
                               sampler s [[sampler(0)]], constant float4& p [[buffer(0)]]) {
            // p.x: render scale, p.y: max radius in render px, p.zw: 1/size
            float c0 = cocT.read(uint2(in.pos.xy)).r * p.x;
            float4 acc = src.read(uint2(in.pos.xy));
            float wsum = 1.0;
            float R = p.y;
            const int N = 64;
            for (int i = 1; i < N; i++) {
                float r = sqrt(float(i) / float(N - 1)) * R;
                float th = float(i) * 2.39996323;
                float2 uv = in.uv + float2(cos(th), sin(th)) * r * p.zw;
                float cs = cocT.sample(s, uv).r * p.x;
                float reach = cs < 0.0 ? -cs : min(cs, max(c0, 0.0));
                float w = saturate(reach - r + 1.0);
                acc += src.sample(s, uv) * w;
                wsum += w;
            }
            return acc / wsum;
        }

        // A text layer's summed glyph coverage (cover_fs), tinted with its premultiplied colour p.
        fragment float4 union_fs(FS in [[stage_in]], texture2d<float> cov [[texture(0)]], constant float4& p [[buffer(0)]]) {
            return p * min(cov.read(uint2(in.pos.xy)).r, 1.0);
        }

        // Bloom: soft-threshold prefilter, 4-tap box downsample, 9-tap tent upsample (additive).
        // The prefilter reads the world with the 2D overlay over it, so 2D layers glow too.
        static float4 brightTap(texture2d<float> src, texture2d<float> ov, sampler s, float2 uv) {
            float4 o = ov.sample(s, uv);
            return o + src.sample(s, uv) * (1.0 - o.a);
        }
        fragment float4 bright_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]],
                                  texture2d<float> ov [[texture(1)]], sampler s [[sampler(0)]],
                                  constant float4& p [[buffer(0)]]) {
            float2 t = p.zw;
            float4 c = (brightTap(src, ov, s, in.uv + t * float2(-0.5, -0.5)) + brightTap(src, ov, s, in.uv + t * float2(0.5, -0.5)) +
                        brightTap(src, ov, s, in.uv + t * float2(-0.5, 0.5)) + brightTap(src, ov, s, in.uv + t * float2(0.5, 0.5))) * 0.25;
            float l = max(c.r, max(c.g, c.b));
            float knee = max(p.x * 0.15, 1e-4);
            float soft = clamp(l - p.x + knee, 0.0, 2.0 * knee);
            soft = soft * soft / (4.0 * knee);
            float w = max(soft, l - p.x) / max(l, 1e-4);
            return float4(c.rgb * w, 0);
        }

        fragment float4 down_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
                                constant float4& p [[buffer(0)]]) {
            float2 t = p.zw;
            return (src.sample(s, in.uv + t * float2(-1, -1)) + src.sample(s, in.uv + t * float2(1, -1)) +
                    src.sample(s, in.uv + t * float2(-1, 1)) + src.sample(s, in.uv + t * float2(1, 1))) * 0.25;
        }

        fragment float4 up_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]],
                              constant float4& p [[buffer(0)]]) {
            float2 t = p.zw;
            float4 c = src.sample(s, in.uv) * 4.0;
            c += (src.sample(s, in.uv + t * float2(-1, 0)) + src.sample(s, in.uv + t * float2(1, 0)) +
                  src.sample(s, in.uv + t * float2(0, -1)) + src.sample(s, in.uv + t * float2(0, 1))) * 2.0;
            c += src.sample(s, in.uv + t * float2(-1, -1)) + src.sample(s, in.uv + t * float2(1, -1)) +
                 src.sample(s, in.uv + t * float2(-1, 1)) + src.sample(s, in.uv + t * float2(1, 1));
            return c / 16.0;
        }

        struct PostU {
            float4 a;  // exposure multiplier, contrast, saturation, tonemap
            float4 b;  // vignette amount, vignette softness, grain amount, grain seed
            float4 c;  // bloom intensity, bloom enabled, aspect, grade overlay
            float4 d;  // fade colour (linear rgb), fade visibility (1 = fully visible)
        };

        static float3 toSRGB(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
        static float3 toLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
        static float hash(float2 p, float s) {
            float3 p3 = fract(float3(p.xyx) * 0.1031 + s * 0.1337);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }

        // Grades the world layer (+ bloom), then composites the 2D overlay on top ungraded unless
        // u.c.w is set. Grain goes over everything so type and footage share the same texture.
        fragment float4 final_fs(FS in [[stage_in]], texture2d<float> src [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                                 texture2d<float> overlay [[texture(2)]], sampler s [[sampler(0)]], constant PostU& u [[buffer(0)]]) {
            float4 c = src.read(uint2(in.pos.xy));
            float4 ov = overlay.read(uint2(in.pos.xy));
            // Bloom lies over everything: over the world and a graded overlay it is graded with them; over an
            // ungraded overlay it is added ungraded after the overlay (below).
            float3 glow = u.c.y > 0.5 ? bloom.sample(s, in.uv).rgb * u.c.x : float3(0);
            if (u.c.w > 0.5) { c = ov + c * (1.0 - ov.a); ov = float4(0); }
            c.rgb += glow;
            float3 col = c.rgb * u.a.x;
            if (u.a.w > 0.5) col = saturate((col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14));
            float l = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = max(mix(float3(l), col, u.a.z), 0.0);
            float3 sc = toSRGB(saturate(col));
            if (u.a.y != 1.0) sc = (sc - 0.5 * c.a) * u.a.y + 0.5 * c.a;
            if (u.b.x > 0) {
                float2 d = (in.uv - 0.5) * float2(u.c.z, 1.0);
                float r = length(d) / length(float2(u.c.z, 1.0) * 0.5);
                sc *= 1.0 - u.b.x * smoothstep(1.0 - u.b.y, 1.0 + u.b.y * 0.25, r);
            }
            float3 lin = toLinear(saturate(sc));
            lin = ov.rgb + lin * (1.0 - ov.a) + glow * ov.a;
            float a = saturate(ov.a + c.a * (1.0 - ov.a));
            if (u.d.w < 1.0) { lin = mix(u.d.rgb * a, lin, u.d.w); }
            if (u.b.z > 0) {
                float n = (hash(in.pos.xy, u.b.w) + hash(in.pos.xy + 17.0, u.b.w + 3.1) - 1.0);
                lin = toLinear(saturate(toSRGB(saturate(lin)) + n * u.b.z * a));
            }
            return float4(lin, a);
        }
        """
}
