//
//  AsciiAtlas.swift
//  Artlify / RenderKit
//
//  Builds a single-row glyph-strip MTLTexture (R8) from a fixed ASCII
//  ramp ordered sparsest → densest. The Ascii.metal fragment shader
//  picks one glyph per cell by luminance and samples this strip.
//

import Foundation
import Metal
import AppKit
import CoreGraphics

enum AsciiAtlas {

    /// Sparse → dense. Keep this in sync with the Metal shader's
    /// `glyphCount` uniform.
    static let glyphs: [Character] = [
        " ", ".", ":", "-", "=", "+", "*", "#", "%", "@"
    ]

    /// Per-glyph cell edge in pixels. The atlas is `cellSize * count`
    /// wide and `cellSize` tall.
    static let cellSize: Int = 16

    /// Generate the atlas texture. Returns nil on any allocation
    /// failure; caller should disable the ASCII layer in that case.
    static func makeTexture(device: MTLDevice) -> MTLTexture? {
        let n = glyphs.count
        let w = cellSize * n
        let h = cellSize
        let bytesPerRow = w

        // Greyscale 8-bit context — the shader only needs alpha.
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background, white glyphs.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(cellSize) * 0.85,
            weight: .bold
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        for (i, ch) in glyphs.enumerated() {
            let s = String(ch) as NSString
            let size = s.size(withAttributes: attrs)
            let x = CGFloat(i * cellSize) + (CGFloat(cellSize) - size.width) * 0.5
            let y = (CGFloat(cellSize) - size.height) * 0.5
            s.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc),
              let data = ctx.data
        else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return tex
    }
}
