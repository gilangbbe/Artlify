//
//  Ascii.metal
//  Artlify / RenderKit
//
//  Renders the camera-feed-through-the-silhouette as a grid of ASCII
//  glyphs (sparse → dense by luminance), gated by the person mask.
//  A single audio-triggered shockwave ring propagates outward from a
//  body-anchored origin, briefly brightening the glyphs it crosses
//  (so a clap reads as a ripple of denser characters expanding from
//  the body).
//
//  Bindings:
//    texture(0)  — camera (BGRA, top-left uv)
//    texture(1)  — person mask (R8)
//    texture(2)  — glyph atlas (R8, N glyphs in a horizontal strip,
//                  glyph 0 = sparsest, glyph N-1 = densest)
//    buffer(0)   — AsciiUniforms
//

#include <metal_stdlib>
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

struct AsciiUniforms {
    float2 viewport;     // drawable size in pixels
    float  cellSize;     // glyph cell edge in pixels
    float  glyphCount;   // N glyphs in atlas

    float  audioStrength;
    float  audioLevel;
    float  audioLow;
    float  audioTransient;

    // Shockwave ring (single, restarted on each detected transient).
    float2 shockOrigin;  // uv (top-left)
    float  shockAge;     // seconds since last trigger; <0 = inactive
    float  shockSpeed;   // uv per second (radius = age * speed)
    float  shockWidth;   // gaussian ring width in uv
    float  shockPeak;    // 0..1 brightness boost at ring center
};

fragment float4 ascii_fragment(
    VSOut in [[stage_in]],
    texture2d<float, access::sample> cam   [[texture(0)]],
    texture2d<float, access::sample> mask  [[texture(1)]],
    texture2d<float, access::sample> atlas [[texture(2)]],
    constant AsciiUniforms&          u     [[buffer(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    // ---- Cell quantisation. Every pixel resolves to the same glyph
    // for all pixels inside its grid cell, so the screen reads as a
    // text terminal rather than a smooth image.
    float2 px         = in.uv * u.viewport;
    float  cell       = max(2.0, u.cellSize);
    float2 cellIdx    = floor(px / cell);
    float2 cellCtrPx  = (cellIdx + 0.5) * cell;
    float2 cellUV     = cellCtrPx / u.viewport;

    // ---- Mask gate. Only show glyphs where the person is. A soft
    // edge keeps the silhouette from looking like a stamped cutout.
    float m = mask.sample(s, cellUV).r;
    float gate = smoothstep(0.05, 0.30, m);
    if (gate <= 0.001) discard_fragment();

    // ---- Luminance from the camera, perceptual weights.
    float3 c   = cam.sample(s, cellUV).rgb;
    float  lum = dot(c, float3(0.299, 0.587, 0.114));

    // Audio: bass swells brightness (so the whole text "breathes"
    // with low end), broadband level adds steady fill.
    float audioBoost = u.audioStrength *
                       (0.35 * u.audioLevel + 0.25 * u.audioLow);
    lum = saturate(lum + audioBoost);

    // ---- Shockwave ring. Radius advances with shockAge; gaussian
    // band around it brightens whichever cells it currently overlaps.
    if (u.shockAge >= 0.0) {
        float2 toCell = cellUV - u.shockOrigin;
        float  d      = length(toCell);
        float  radius = u.shockAge * u.shockSpeed;
        float  edge   = (d - radius) / max(0.001, u.shockWidth);
        float  ring   = exp(-edge * edge);
        // Fade the ring as it ages so old shockwaves don't linger.
        float  fade   = exp(-u.shockAge * 2.2);
        lum = saturate(lum + ring * fade * u.shockPeak);
    }

    // ---- Glyph selection: luminance → atlas index.
    int   N    = max(1, int(u.glyphCount));
    float fidx = lum * float(N - 1);
    int   idx  = int(clamp(fidx, 0.0, float(N - 1)));

    // Local uv inside the current cell, then into the atlas strip.
    float2 local = fract(px / cell);                       // 0..1
    float2 atlasUV = float2((float(idx) + local.x) / float(N),
                            local.y);
    float  g = atlas.sample(s, atlasUV).r;

    // Phosphor-greenish tint, slightly hotter for brighter cells.
    float3 col = mix(float3(0.45, 0.95, 0.55),
                     float3(0.85, 1.00, 0.70),
                     lum) * g;

    float a = g * gate;
    if (a <= 0.001) discard_fragment();
    // Premultiplied for the standard alpha-over blend.
    return float4(col * a, a);
}
