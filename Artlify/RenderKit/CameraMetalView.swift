//
//  CameraMetalView.swift
//  Artlify / RenderKit
//
//  NSViewRepresentable that wires CameraMetalRenderer to an MTKView,
//  so SwiftUI can render the live camera passthrough.
//

import SwiftUI
import MetalKit

public struct CameraMetalView: NSViewRepresentable {
    public let renderer: CameraMetalRenderer

    public init(renderer: CameraMetalRenderer) {
        self.renderer = renderer
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        view.layer?.isOpaque = true
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        // Renderer is a class — no per-update wiring needed.
    }
}
