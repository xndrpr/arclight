// Metal source for the instanced 3D passes: sprites, shadows, beams, light pools and cones. Part of
// `ShaderSource.main`.

extension ShaderSource {
    static let world = """
        // ---- Instanced 3D: sprites, shadows, beams, light pools -----------------
        // Quad instance: base point + two world-space edge vectors.
        // extra: rim colour (linear rgb), rim-layer v offset in the atlas (0 = none).
        struct QuadI { float4 pos; float4 a; float4 b; float4 uv; float4 color; float4 extra; };

        // Sprite/shadow/beam: corner = pos + a * (u - 0.5) + b * v  (v = 0 at the base).
        vertex IOut quad_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device QuadI* inst [[buffer(0)]], constant float4x4& vp [[buffer(2)]]) {
            QuadI q = inst[iid];
            float2 c = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
            float3 p = q.pos.xyz + q.a.xyz * (c.x - 0.5) + q.b.xyz * c.y;
            IOut o;
            o.pos = vp * float4(p, 1);
            o.vz = o.pos.w;
            o.uv = float2(mix(q.uv.x, q.uv.z, c.x), mix(q.uv.w, q.uv.y, c.y));
            o.color = q.color;
            o.params = float4(c, q.pos.w, 0);
            o.extra = q.extra;
            return o;
        }

        fragment FOut sprite_fs(IOut in [[stage_in]], constant FrameU& f [[buffer(1)]],
                                texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]]) {
            float4 t = atlas.sample(s, in.uv);
            float4 c = t * in.color;
            float rim = in.params.z;  // lit * rim strength
            if (in.extra.w > 0) {
                // Drawn highlight strokes along the top edges (vector items), composited over the ink.
                float ra = atlas.sample(s, in.uv + float2(0, in.extra.w)).a * rim * in.color.a;
                c = float4(in.extra.rgb * ra, ra) + c * (1.0 - ra);
            } else {
                // Fallback for glyph/image items: brighten the top of the sprite.
                c.rgb += t.a * in.color.a * rim * pow(saturate(in.params.y), 3.0);
            }
            return finish(c, in.vz, f);
        }

        // Volumetric-looking beam: narrow at the top, soft edges, fading upward. uv from params.xy.
        fragment FOut beam_fs(IOut in [[stage_in]], constant FrameU& f [[buffer(1)]]) {
            float x = abs(in.params.x * 2.0 - 1.0);
            float v = in.params.y;
            float w = mix(1.0, 0.35, v);
            float a = (1.0 - smoothstep(w * 0.25, w, x)) * pow(1.0 - v, 1.4);
            return finish(in.color * a, in.vz, f);
        }

        // Ground decal centred on pos with half-axes a and b.
        vertex IOut decal_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device QuadI* inst [[buffer(0)]], constant float4x4& vp [[buffer(2)]]) {
            QuadI q = inst[iid];
            float2 c = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
            float3 p = q.pos.xyz + q.a.xyz * c.x + q.b.xyz * c.y;
            IOut o;
            o.pos = vp * float4(p, 1);
            o.vz = o.pos.w;
            o.uv = c;
            o.color = q.color;
            o.params = q.uv; // x: softness, y: falloff power
            o.extra = q.extra;
            return o;
        }

        fragment FOut pool_fs(IOut in [[stage_in]], constant FrameU& f [[buffer(1)]]) {
            float d = length(in.uv);
            float a = 1.0 - smoothstep(1.0 - in.params.x, 1.0, d);
            a *= pow(saturate(1.0 - d * d * 0.35), in.params.y);
            return finish(in.color * a, in.vz, f);
        }

        // Light cones: convex hull of the lamp point and the pool circle, built on the CPU in clip space.
        // pos = (ndc.x, ndc.y, gradient coordinate 0 at lamp -> 1 at pool centre, view depth).
        struct ConeV { float4 pos; float4 color; };
        struct ConeOut { float4 pos [[position]]; float g [[center_no_perspective]]; float vz; float4 color [[flat]]; };

        vertex ConeOut cone_vs(uint vid [[vertex_id]], const device ConeV* v [[buffer(0)]]) {
            ConeV q = v[vid];
            ConeOut o; o.pos = float4(q.pos.xy, 0.5, 1); o.g = q.pos.z; o.vz = q.pos.w; o.color = q.color; return o;
        }

        fragment FOut cone_fs(ConeOut in [[stage_in]], constant FrameU& f [[buffer(1)]]) {
            // Cone gradient: 0 at the lamp, 0.05 at 55%, 0.14 at the pool (scaled by color.a = intensity).
            float g = saturate(in.g);
            float a = g < 0.55 ? mix(0.0, 0.05, g / 0.55) : mix(0.05, 0.14, (g - 0.55) / 0.45);
            return finish(float4(in.color.rgb * a * in.color.a, 0), in.vz, f);
        }
        """
}
