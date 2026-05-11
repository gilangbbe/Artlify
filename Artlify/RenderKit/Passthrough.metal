//
//  Passthrough.metal
//  Artlify / RenderKit
//
//  Minimal full-screen blit. Samples a single texture and writes it
//  to the drawable. This is the foundation that the temporal-blend
//  and post-FX passes will be added to in later milestones.
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Renders a full-screen triangle without a vertex buffer.
// vid 0..2 covers the screen; UVs are flipped vertically because
// CoreVideo BGRA textures are top-left origin while Metal expects
// bottom-left for default orientation.
vertex VSOut passthrough_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    float2 uv[3] = {
        float2(0.0, 2.0),
        float2(0.0, 0.0),
        float2(2.0, 0.0)
    };
    VSOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = uv[vid];
    return out;
}

fragment float4 passthrough_fragment(VSOut in [[stage_in]],
                                     texture2d<float, access::sample> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    return src.sample(s, in.uv);
}
