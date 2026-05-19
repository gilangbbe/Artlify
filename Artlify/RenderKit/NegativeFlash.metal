//
//  NegativeFlash.metal
//  Artlify / RenderKit
//
//  Full-screen "negative camera" flash. Triggered by the open-hand
//  gesture (see VisionKit/HandOpen.swift + AppShell/ContentView).
//
//  The fragment shader inverts the raw camera RGB and writes it as a
//  premultiplied colour with alpha = intensity, so the alpha-blend
//  configured on the Swift side fades the inverted image in over
//  whatever the stylised pipeline produced and back out a few frames
//  later. The whole thing is one fullscreen triangle and one texture
//  sample per fragment.
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct NegativeFlashUniforms {
    float  intensity;   // 0..1 fade
    float  _pad0;
    float2 _pad1;
    float3 tint;        // RGB multiplier on the inverted image (1,1,1 = pure negative)
    float  _pad2;
};

fragment float4 negflash_fragment(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> cam [[texture(0)]],
    constant NegativeFlashUniforms&  u   [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    if (u.intensity <= 0.001) {
        discard_fragment();
        return float4(0.0);
    }
    float3 c   = cam.sample(s, in.uv).rgb;
    float3 inv = (float3(1.0) - c) * u.tint;
    float  a   = u.intensity;
    return float4(inv * a, a);   // premultiplied
}
