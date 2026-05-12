//
//  DiffusionBenchmark.swift
//  Artlify / AppShell
//
//  M1 verification surface AND the central "what knobs is the user
//  pulling on the diffusion pipeline" object. The same benchmark
//  drives both the one-shot button and the M3 live loop, so its
//  config (compute units, model variant, prompt, steps, strength) is
//  the single source of truth.
//
//  Live A/B knobs added in M3.5 (perf optimisation pass):
//    * `ComputeUnitChoice` — .ane / .gpu / .all → MLComputeUnits
//    * `ModelVariant` — picks a sibling directory under
//      Application Support/Artlify/Models/ and the input resolution
//      (sd-turbo = 512×512, sd-turbo-384 = 384×384).
//
//  Changing either knob marks the pipeline as needing rebuild and
//  resets loadState. The user must then click "Load model" again.
//  This keeps the rebuild explicit (it costs 5–10 s) and avoids
//  surprising the live loop with a hot-swapped pipeline.
//

import Foundation
import Observation
import OSLog
import CoreGraphics
import CoreML
import AppKit

enum ComputeUnitChoice: String, CaseIterable, Identifiable {
    case ane    // .cpuAndNeuralEngine
    case gpu    // .cpuAndGPU
    case all    // .all (CPU + GPU + ANE, CoreML decides)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ane: return "CPU + ANE"
        case .gpu: return "CPU + GPU"
        case .all: return "All (auto)"
        }
    }

    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .ane: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .all: return .all
        }
    }
}

enum ModelVariant: String, CaseIterable, Identifiable {
    case square512   // ~/Library/Application Support/Artlify/Models/sd-turbo
    case square384   // ~/Library/Application Support/Artlify/Models/sd-turbo-384

    var id: String { rawValue }

    var folderName: String {
        switch self {
        case .square512: return "sd-turbo"
        case .square384: return "sd-turbo-384"
        }
    }

    var sideLength: Int {
        switch self {
        case .square512: return 512
        case .square384: return 384
        }
    }

    var label: String { "\(sideLength)×\(sideLength)" }
}

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
    private(set) var pipeline: DiffusionPipeline

    // ---- User-tunable inputs (read by both the benchmark button and the live loop)
    var prompt: String = ""
    var stepCount: Int = 4
    var strength: Float = 0.78

    var computeUnits: ComputeUnitChoice = .ane {
        didSet { if oldValue != computeUnits { invalidatePipeline() } }
    }
    var variant: ModelVariant = .square384 {
        didSet { if oldValue != variant { invalidatePipeline() } }
    }

    /// PromptKit composer. Owns the active StylePreset, free-text extras,
    /// and pose/motion-modifier toggles. The live driver reads
    /// `effectivePrompt` (composer + latestVisionFrame) on every pass.
    let composer = PromptComposer()

    /// Most recently observed Vision frame, pushed in by the UI. Optional
    /// because Vision can be paused or briefly empty.
    var latestVisionFrame: VisionFrame?

    /// What the driver actually sends to the diffusion pipeline.
    var effectivePrompt: String {
        let composed = composer.compose(with: latestVisionFrame).prompt
        let extras = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if extras.isEmpty { return composed }
        return composed + ", " + extras
    }

    private(set) var loadState: LoadState = .idle
    private(set) var runState: RunState = .idle
    private(set) var resultImage: CGImage?

    /// Resolution to feed into `pipeline.generate(startingImage:)`. Tracks `variant`.
    var inputSide: Int { variant.sideLength }

    var modelDirectory: URL {
        DiffusionPipeline.defaultModelDirectory(modelName: variant.folderName)
    }

    var modelDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.path)
    }

    init() {
        // Build the initial pipeline against the *current* variant +
        // computeUnits defaults. Using the bare `defaultModelDirectory()`
        // here would hardcode the 512×512 sd-turbo folder, so picking a
        // different default `variant` (e.g. `.square384`) would silently
        // load the wrong model and crash the VAE encoder with shape errors
        // on the first pass.
        //
        // Note: we can't read `self.variant` / `self.computeUnits` here
        // because @Observable rewrites them as computed and they're
        // off-limits before all stored properties are initialised. So we
        // duplicate the default literals — keep them in sync with the
        // `var variant = ...` / `var computeUnits = ...` declarations
        // above.
        let initialVariant: ModelVariant = .square384
        let initialUnits: ComputeUnitChoice = .ane
        self.pipeline = DiffusionPipeline(
            modelDirectory: DiffusionPipeline.defaultModelDirectory(
                modelName: initialVariant.folderName
            ),
            computeUnits: initialUnits.mlComputeUnits
        )
    }

    func revealModelFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: modelDirectory,
                                withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    /// Tear down the loaded pipeline and rebuild it under the current
    /// computeUnits + variant. UI must call `load()` afterwards.
    private func invalidatePipeline() {
        let oldPipeline = self.pipeline
        Task { await oldPipeline.unload() }
        self.pipeline = DiffusionPipeline(
            modelDirectory: modelDirectory,
            computeUnits: computeUnits.mlComputeUnits
        )
        loadState = .idle
        runState = .idle
        resultImage = nil
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
        let side = self.inputSide
        guard let cg = PixelBufferToCGImage.makeCGImage(
            from: pb,
            resizedTo: CGSize(width: side, height: side)
        ) else {
            runState = .failed("Failed to convert camera frame to CGImage.")
            return
        }

        runState = .running
        let prompt = self.effectivePrompt
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
