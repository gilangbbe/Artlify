//
//  CVPixelBuffer+CGImage.swift
//  Artlify / DiffusionKit
//
//  Lightweight pixel-buffer → CGImage helper used to feed CaptureKit
//  frames into the diffusion pipeline. We allocate a small CIContext
//  once and reuse it; this is much faster than creating a new context
//  per call.
//

import CoreImage
import CoreVideo
import CoreGraphics
import Metal

public enum PixelBufferToCGImage {
    private static let ciContext: CIContext = {
        // Use the default Metal device when available for fast conversion.
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    public static func makeCGImage(from pixelBuffer: CVPixelBuffer,
                                   resizedTo size: CGSize? = nil) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard let size else {
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        // The CoreML VAE encoder expects an EXACT NxN input (512×512 for SD-Turbo).
        // Going through `CIImage.transformed(by:)` + `createCGImage(_:from:)` can
        // off-by-one due to floating-point extent rounding. Instead we:
        //   1. Center-crop the source CIImage to a square in source pixel space.
        //   2. Render that square into a fixed-size CGContext at exactly `size`.
        //
        // This guarantees the returned CGImage has integer width == Int(size.width)
        // and height == Int(size.height), no matter the source resolution or aspect.
        let srcW = ciImage.extent.width
        let srcH = ciImage.extent.height
        let side = min(srcW, srcH)
        let cropX = ciImage.extent.origin.x + (srcW - side) / 2.0
        let cropY = ciImage.extent.origin.y + (srcH - side) / 2.0
        let squareRect = CGRect(x: cropX, y: cropY, width: side, height: side)

        let outW = Int(size.width.rounded())
        let outH = Int(size.height.rounded())

        // Render the cropped square into a CG bitmap of exactly outW × outH.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: outW,
                                  height: outH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else {
            return nil
        }

        // Get the cropped square as a CGImage from CoreImage at native resolution,
        // then let CG scale it into the fixed-size context.
        guard let squareCG = ciContext.createCGImage(ciImage, from: squareRect) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(squareCG, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }
}
