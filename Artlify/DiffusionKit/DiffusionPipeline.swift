//
//  DiffusionPipeline.swift
//  Artlify / DiffusionKit
//
//  Loads a CoreML Stable Diffusion model from a known on-disk location
//  and runs single-shot img2img passes for the M1 benchmark.
//
//  Design notes (see ProjectDocument.md §6.3 and Roadmap.md M1):
//
//    * The model is NOT bundled in the app. It lives in
//      ~/Library/Application Support/Artlify/Models/<modelName>/
//      The user is expected to drop a converted .mlmodelc bundle there
//      (TextEncoder.mlmodelc, Unet.mlmodelc, VAEDecoder.mlmodelc,
//       VAEEncoder.mlmodelc, vocab.json, merges.txt — see
//       apple/ml-stable-diffusion README for conversion steps).
//    * The pipeline is wrapped in a Swift `actor` so that prompt updates
//      and `generate` calls are serialized and never overlap; a second
//      call while one is in flight will wait, NOT queue more work behind
//      it. Callers are expected to use the latest-frame-wins pattern
//      (see CaptureKit) and simply not call `generate` while one is
//      already running.
//    * Reduced-memory mode is enabled by default: on a 24 GB M5 base we
//      need to share VRAM with Vision + Metal textures + the live
//      camera path, so we trade a few hundred ms per call for ~3 GB of
//      headroom.
//

import Foundation
import CoreML
import CoreGraphics
import OSLog
@preconcurrency import StableDiffusion

public struct DiffusionRunStats: Sendable {
    public let totalSeconds: Double
    public let stepCount: Int
    public let width: Int
    public let height: Int
    public let strength: Float
    public let prompt: String
}

public enum DiffusionError: Error, LocalizedError {
    case modelDirectoryMissing(URL)
    case noResultProduced
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .modelDirectoryMissing(let url):
            return "Model directory not found at \(url.path). " +
                   "Drop a CoreML-converted Stable Diffusion model bundle there. " +
                   "See README / Journal.md for conversion steps."
        case .noResultProduced:
            return "Diffusion produced no image (safety check or empty result)."
        case .notLoaded:
            return "Diffusion pipeline has not been loaded yet. Call `load()` first."
        }
    }
}

public actor DiffusionPipeline {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "DiffusionKit")

    public let modelDirectory: URL
    public let computeUnits: MLComputeUnits

    private var pipeline: StableDiffusion.StableDiffusionPipeline?

    public init(modelDirectory: URL,
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        self.modelDirectory = modelDirectory
        self.computeUnits = computeUnits
    }

    /// Default model directory under Application Support.
    public static func defaultModelDirectory(modelName: String = "sd-turbo") -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "Artlify", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
            .appending(path: modelName, directoryHint: .isDirectory)
    }

    public var isLoaded: Bool { pipeline != nil }

    /// Load model resources. Expensive (multi-second). Call once at startup.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw DiffusionError.modelDirectoryMissing(modelDirectory)
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let t0 = CFAbsoluteTimeGetCurrent()
        let pipe = try StableDiffusion.StableDiffusionPipeline(
            resourcesAt: modelDirectory,
            controlNet: [],
            configuration: config,
            disableSafety: true,
            reduceMemory: true
        )
        try pipe.loadResources()
        let dt = CFAbsoluteTimeGetCurrent() - t0
        self.pipeline = pipe
        log.info("Loaded SD pipeline in \(dt, format: .fixed(precision: 2)) s from \(self.modelDirectory.path, privacy: .public)")
    }

    /// Run a single img2img pass against the supplied starting image.
    /// Returns the generated image plus timing stats.
    public func generate(prompt: String,
                         startingImage: CGImage,
                         strength: Float = 0.55,
                         stepCount: Int = 2,
                         seed: UInt32 = 0) throws -> (image: CGImage, stats: DiffusionRunStats) {
        guard let pipe = pipeline else { throw DiffusionError.notLoaded }

        var cfg = StableDiffusion.PipelineConfiguration(prompt: prompt)
        cfg.startingImage = startingImage
        cfg.strength = max(0.05, min(0.99, strength))
        cfg.stepCount = max(1, stepCount)
        cfg.imageCount = 1
        cfg.seed = seed
        cfg.guidanceScale = 0.0           // SD Turbo is trained without CFG
        cfg.disableSafety = true
        cfg.schedulerType = .dpmSolverMultistepScheduler

        let t0 = CFAbsoluteTimeGetCurrent()
        let images = try pipe.generateImages(configuration: cfg) { _ in true }
        let dt = CFAbsoluteTimeGetCurrent() - t0

        guard let img = images.first ?? nil else {
            throw DiffusionError.noResultProduced
        }
        let stats = DiffusionRunStats(
            totalSeconds: dt,
            stepCount: cfg.stepCount,
            width: img.width,
            height: img.height,
            strength: cfg.strength,
            prompt: prompt
        )
        log.info("img2img: \(dt, format: .fixed(precision: 3)) s, \(cfg.stepCount) steps, strength \(cfg.strength), \(img.width)x\(img.height)")
        return (img, stats)
    }

    public func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }
}
