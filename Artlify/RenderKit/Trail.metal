//
//  Trail.metal
//  Artlify / RenderKit
//
//  Single fragment shader used for the "trail accumulator" feedback
//  loop. Each frame we ping-pong two offscreen textures:
//
//    Pass A — render `accumPrev * decay` into accumNext.
//    Pass B — draw the particles additively into accumNext.
//    Pass C — blit accumNext to the drawable (passthrough_fragment).
//
//  `decay` close to 1.0 = long, smeared trails; closer to 0.85 = short,
//  fluid trails; 0.0 = no trails (effectively the same as not running
//  this pass at all).
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct TrailUniforms {
    float decay;
};

fragment float4 trail_decay_fragment(
    VSOut                              in     [[stage_in]],
    texture2d<float, access::sample>   src    [[texture(0)]],
    constant TrailUniforms&            u      [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float4 c = src.sample(s, in.uv);
    return c * u.decay;
}
