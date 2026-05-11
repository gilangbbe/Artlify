//
//  DiffusionBenchmark.swift
//  Artlify / AppShell
//
//  M1 verification surface: load the diffusion model, grab the latest
//  camera frame, run a single img2img pass, and surface the result +
//  timing in the UI. This is intentionally a "benchmark" rather than
//  the final live loop (which is M3) — it answers the assumption in
//  ProjectDocument.md §13: "SD Turbo at 512×512, 2 steps, fp16,
//  achieves ≥3 FPS on M5 base."
//

import Foundation
import Observation
import OSLog
import CoreGraphics
import CoreML
import AppKit

@MainActor
@Observable
final class DiffusionBenchmark {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum RunState: Equatable {
        case idle
        case running
        case done(seconds: Double, steps: Int)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.biru.Artlify", category: "Benchmark")
    private let pipeline: DiffusionPipeline

    var prompt: String = "oil painting, swirling brushstrokes, vivid colors"
    var stepCount: Int = 2
    var strength: Float = 0.55

    private(set) var loadState: LoadState = .idle
    private(set) var runState: RunState = .idle
    private(set) var resultImage: CGImage?
    private(set) var modelDirectory: URL

    init() {
        let dir = DiffusionPipeline.defaultModelDirectory()
        self.modelDirectory = dir
        self.pipeline = DiffusionPipeline(modelDirectory: dir,
                                          computeUnits: .cpuAndNeuralEngine)
    }

    var modelDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.path)
    }

    func revealModelFolder() {
        let fm = FileManager.default
        // Make sure the directory exists so Finder has something to reveal.
        try? fm.createDirectory(at: modelDirectory,
                                withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    func load() {
        guard loadState != .loading, loadState != .loaded else { return }
        loadState = .loading
        let pipeline = self.pipeline
        Task { [weak self] in
            do {
                try await pipeline.load()
                self?.loadState = .loaded
            } catch {
                self?.loadState = .failed(error.localizedDescription)
                self?.log.error("load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func run(using session: CameraSession) {
        guard runState != .running else { return }
        guard loadState == .loaded else {
            runState = .failed("Pipeline not loaded.")
            return
        }
        guard let pb = session.latestPixelBuffer else {
            runState = .failed("No camera frame yet.")
            return
        }
        guard let cg = PixelBufferToCGImage.makeCGImage(
            from: pb,
            resizedTo: CGSize(width: 512, height: 512)
        ) else {
            runState = .failed("Failed to convert camera frame to CGImage.")
            return
        }

        runState = .running
        let prompt = self.prompt
        let steps = self.stepCount
        let strength = self.strength
        let pipeline = self.pipeline
        Task { [weak self] in
            do {
                let result = try await pipeline.generate(
                    prompt: prompt,
                    startingImage: cg,
                    strength: strength,
                    stepCount: steps
                )
                self?.resultImage = result.image
                self?.runState = .done(seconds: result.stats.totalSeconds,
                                       steps: result.stats.stepCount)
            } catch {
                self?.runState = .failed(error.localizedDescription)
                self?.log.error("run failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
