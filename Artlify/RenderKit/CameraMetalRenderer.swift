//
//  CameraMetalRenderer.swift
//  Artlify / RenderKit
//
//  MTKView delegate that renders the most recently received camera
//  CVPixelBuffer using a passthrough Metal shader. Designed for the
//  v1 architecture in ProjectDocument.md §4: the renderer is the
//  fast consumer, holding only the latest texture and never blocking
//  on producers.
//
//  In M3 this will gain two more textures (aiPrev / aiNext) and a
//  temporal blend; for M0 we just blit the camera frame.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import OSLog

public final class CameraMetalRenderer: NSObject, MTKViewDelegate {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "Renderer")

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Atomic-ish single slot for the latest camera texture. Reads/writes
    /// always happen on the main actor (set from the capture consumer task,
    /// read from MTKView's draw callback which is also main-thread by default).
    private var latestTexture: MTLTexture?

    /// FPS counter (frames drawn that actually had a texture).
    public private(set) var drawnFrames: Int = 0
    public private(set) var droppedFrames: Int = 0
    private var lastFPSReport = CFAbsoluteTimeGetCurrent()

    public init(device: MTLDevice = MTLCreateSystemDefaultDevice()!) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = queue

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard
            let vfn = library.makeFunction(name: "passthrough_vertex"),
            let ffn = library.makeFunction(name: "passthrough_fragment")
        else {
            throw RendererError.shaderNotFound
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipeline = try device.makeRenderPipelineState(descriptor: desc)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw RendererError.textureCacheCreationFailed
        }
        self.textureCache = cache

        super.init()
    }

    /// Push a new camera frame. Replaces any pending frame (latest-wins).
    public func submit(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTex
        )
        guard status == kCVReturnSuccess,
              let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex)
        else {
            droppedFrames += 1
            return
        }
        latestTexture = tex
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing — the passthrough shader uses a full-screen triangle,
        // so the pipeline is resolution-independent.
    }

    public func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let cmd = commandQueue.makeCommandBuffer(),
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        if let tex = latestTexture {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawnFrames += 1

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFPSReport >= 1.0 {
                let fps = Double(drawnFrames) / (now - lastFPSReport)
                log.debug("Render FPS: \(fps, format: .fixed(precision: 1)) (dropped: \(self.droppedFrames))")
                drawnFrames = 0
                droppedFrames = 0
                lastFPSReport = now
            }
        }
        // If no texture yet, the encoder still clears the view.

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

public enum RendererError: Error, LocalizedError {
    case commandQueueUnavailable
    case shaderNotFound
    case textureCacheCreationFailed

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable: return "Could not create a Metal command queue."
        case .shaderNotFound: return "Required Metal shader functions are missing from the default library."
        case .textureCacheCreationFailed: return "Could not create a CVMetalTextureCache."
        }
    }
}
