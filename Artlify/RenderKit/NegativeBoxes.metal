//
//  NegativeBoxes.metal
//  Artlify / RenderKit
//
//  Renders a small set of rectangular "windows" onto the dark
//  installation canvas, each window showing the live camera feed
//  with its colour negated. The boxes are positioned around the
//  detected body joints (wrists, elbows, knees, head, etc.) and
//  flash randomly. Visually the dark room is punctured by stuttering
//  X-ray-like cutouts wherever the body part briefly is.
//
//  Inputs:
//    texture(0)  — latest camera frame (BGRA, top-left uv)
//    buffer(1)   — array of NegBox (rect = cx,cy,hw,hh in uv ; props.x = alpha)
//    buffer(2)   — int count (number of valid entries in buffer(1))
//
//  Output is intended to be alpha-blended over the drawable
//  (sourceFactor = srcAlpha, destFactor = oneMinusSrcAlpha).
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct NegBox {
    float4 rect;   // (centerX, centerY, halfW, halfH) in uv
    float4 props;  // (alpha, _, _, _)
};

fragment float4 negative_boxes_fragment(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> cam [[texture(0)]],
    constant NegBox*                 boxes [[buffer(1)]],
    constant int&                    count [[buffer(2)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float3 outRGB = float3(0.0);
    float  outA   = 0.0;

    // Loop is small (count ≤ MAX_NEG_BOXES = 16 from Swift side) so an
    // unrolled-style pass is fine. Each box contributes a soft-edged
    // negative window; overlapping boxes simply combine alpha.
    for (int i = 0; i < count; i++) {
        NegBox b = boxes[i];
        float2 c   = b.rect.xy;
        float2 hs  = b.rect.zw;
        float  amax = b.props.x;
        if (amax <= 0.001) continue;

        float2 d = abs(in.uv - c);
        if (d.x > hs.x || d.y > hs.y) continue;

        // Soft 15%-of-half-extent edge so the cutouts don't have a
        // hard rectangular line against the dark background.
        float ex = 1.0 - smoothstep(hs.x * 0.85, hs.x, d.x);
        float ey = 1.0 - smoothstep(hs.y * 0.85, hs.y, d.y);
        float a  = amax * ex * ey;
        if (a <= 0.001) continue;

        // Sample the camera at this uv and invert. The intensity of
        // the inversion fades with the box's alpha so flashes feel
        // like soft X-rays rather than abrupt overlays.
        float3 src = cam.sample(s, in.uv).rgb;
        float3 inv = float3(1.0) - src;

        // Combine (over): out = lerp(out, inv, a)
        outRGB = mix(outRGB, inv, a);
        outA   = max(outA, a);
    }

    if (outA <= 0.001) discard_fragment();
    return float4(outRGB, outA);
}
