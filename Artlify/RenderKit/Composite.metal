//
//  Composite.metal
//  Artlify / RenderKit
//
//  M3 fragment shader: blend two stylized textures by a [0..1] weight
//  (temporal blend), then composite the result over the live camera
//  using the soft person-mask alpha. A global `style_strength` lets
//  the UI fade the AI layer in/out.
//
//  Inputs:
//    texture(0) — camera (live, BGRA, 60 Hz)
//    texture(1) — aiPrev (most recent stylized texture, RGBA)
//    texture(2) — aiNext (stylized texture currently fading in, RGBA)
//    texture(3) — mask   (single-channel, R8, person alpha; optional)
//    buffer(0)  — CompositeUniforms { blend_t, style_strength,
//                                     mask_mode, mask_softness }
//
//  mask_mode: 0 = no mask (stylize the whole frame)
//             1 = person-only (stylize where mask == 1)
//             2 = background-only (stylize where mask == 0; person
//                 stays as live camera)
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct CompositeUniforms {
    float blend_t;        // 0 = fully aiPrev, 1 = fully aiNext
    float style_strength; // 0 = pure camera, 1 = full AI
    float mask_mode;      // 0 = full frame (no mask), 1 = person-only, 2 = background-only
    float mask_softness;  // multiplier on mask alpha (0..1+ to bias)
};

fragment float4 composite_fragment(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> camera [[texture(0)]],
    texture2d<float, access::sample> aiPrev [[texture(1)]],
    texture2d<float, access::sample> aiNext [[texture(2)]],
    texture2d<float, access::sample> mask   [[texture(3)]],
    constant CompositeUniforms& u [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float4 cam = camera.sample(s, in.uv);
    float4 prev = aiPrev.sample(s, in.uv);
    float4 next = aiNext.sample(s, in.uv);
    float4 ai   = mix(prev, next, clamp(u.blend_t, 0.0, 1.0));

    float alpha = clamp(u.style_strength, 0.0, 1.0);

    // mask_mode: 0 = no mask (style applies everywhere)
    //            1 = person-only (style where m == 1)
    //            2 = background-only (style where m == 0)
    int mode = int(u.mask_mode + 0.5);
    if (mode == 1 || mode == 2) {
        float m = clamp(mask.sample(s, in.uv).r * u.mask_softness, 0.0, 1.0);
        if (mode == 2) { m = 1.0 - m; }
        alpha *= m;
    }

    float3 rgb = mix(cam.rgb, ai.rgb, alpha);
    return float4(rgb, 1.0);
}
