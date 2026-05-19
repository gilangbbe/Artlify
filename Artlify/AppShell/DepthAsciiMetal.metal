//
//  DepthAsciiMetal.metal
//  Artlify / AppShell — `particles` branch
//
//  Instanced glyph-grid renderer for the scene-aware ASCII depth
//  pass. One instance per tile (typically 96×54 = 5184 instances),
//  one fullscreen quad of 4 vertices drawn as a triangle strip,
//  sampling a small monospaced glyph atlas (R8 luma).
//
//  CPU (DepthAsciiMetalRenderer) decides per-cell glyph, tint,
//  size and horizontal sway, packs them into the `AsciiCell`
//  buffer below. Shaders just place + colour the glyph. This is
//  the right split because the per-cell choice is sub-millisecond
//  on the CPU but per-glyph text-shaping in SwiftUI Canvas was
//  the previous bottleneck.
//

#include <metal_stdlib>
using namespace metal;

struct AsciiCell {
    uint  glyphIndex;   // index into the atlas (row-major)
    uint  colorRGBA;    // 0xRRGGBBAA, sRGB-ish, unpacked in VS
    float sizeScale;    // 0…1, scales the glyph quad inside its cell
    float swayX;        // pixels of horizontal offset (far-band fog)
};

struct AsciiUniforms {
    float2 viewSize;     // drawable size in pixels
    uint2  tilesXY;      // grid resolution (e.g. 96, 54)
    uint2  atlasGrid;    // atlas cell grid (cols, rows)
    float2 atlasCellPx;  // atlas cell size in atlas-texture pixels
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex VOut depth_ascii_vs(uint                vid    [[vertex_id]],
                           uint                iid    [[instance_id]],
                           constant AsciiUniforms& u  [[buffer(0)]],
                           const device AsciiCell*  cells [[buffer(1)]])
{
    AsciiCell c = cells[iid];

    // Cell (x, y) in the grid.
    uint cx = iid % u.tilesXY.x;
    uint cy = iid / u.tilesXY.x;

    float2 cellSize = u.viewSize / float2(u.tilesXY);
    float2 cellOrigin = float2(cx, cy) * cellSize;

    // Triangle-strip quad corners: vid 0=BL, 1=BR, 2=TL, 3=TR.
    float2 corner = float2(
        (vid == 1 || vid == 3) ? 1.0 : 0.0,
        (vid >= 2)             ? 1.0 : 0.0
    );

    float2 quadSize = cellSize * c.sizeScale;
    float2 pad      = (cellSize - quadSize) * 0.5;
    float2 pxPos    = cellOrigin + pad + corner * quadSize + float2(c.swayX, 0.0);

    // Pixel → NDC (MTKView's origin is top-left, Metal NDC is y-up).
    float2 ndc = pxPos / u.viewSize * 2.0 - 1.0;
    ndc.y = -ndc.y;

    // Atlas UV: cell position in the atlas → uv rectangle.
    uint   ax        = c.glyphIndex % u.atlasGrid.x;
    uint   ay        = c.glyphIndex / u.atlasGrid.x;
    float2 atlasSize = u.atlasCellPx * float2(u.atlasGrid);
    float2 uvOrigin  = float2(ax, ay) * u.atlasCellPx / atlasSize;
    float2 uvSize    = u.atlasCellPx / atlasSize;

    VOut o;
    o.position = float4(ndc, 0.0, 1.0);
    // Atlas top→down growth matches `corner.y` 0=top, 1=bottom for
    // SwiftUI cell convention.
    o.uv       = uvOrigin + corner * uvSize;

    // Unpack 0xRRGGBBAA → float4. Premultiply later by atlas luma.
    uint rgba = c.colorRGBA;
    o.color = float4(
        float((rgba >> 24) & 0xFFu),
        float((rgba >> 16) & 0xFFu),
        float((rgba >> 8)  & 0xFFu),
        float( rgba        & 0xFFu)
    ) / 255.0;
    return o;
}

fragment float4 depth_ascii_fs(VOut                  in    [[stage_in]],
                               texture2d<float, access::sample> atlas [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear,
                        min_filter::linear,
                        address::clamp_to_edge);
    float a = atlas.sample(s, in.uv).r;
    // Premultiplied output: src colour scaled by atlas luma and the
    // cell's own alpha. Standard `.sourceOver` blend with
    // premultiplied source.
    float alpha = in.color.a * a;
    return float4(in.color.rgb * alpha, alpha);
}
