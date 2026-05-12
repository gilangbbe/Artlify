//
//  LiveDiffusionDriver.swift
//  Artlify / AppShell
//
//  M3 driver: continuously runs DiffusionPipeline.generate against
//  the latest CameraSession frame, pushes each result into the
//  renderer for temporal blending. Not a queue — strict
//  latest-frame-wins.
//
//  Holds a reference to the DiffusionBenchmark settings object
//  rather than the pipeline directly, so changes to compute units
//  or model variant (which rebuild `benchmark.pipeline`) are
//  picked up on the next loop iteration. The driver does NOT need
//  to be restarted after a rebuild — it'll just see "model not
//  loaded" until the user re-clicks Load.
//

import Foundation
import Observation
import OSLog
import CoreGraphics

@MainActor
@Observable
final class LiveDiffusionDriver {

    enum Status: Equatable {
        case idle
        case waitingForModel
        case running
        case stalled(reason: String)
        case failed(String)
    }

    private let log = Logger(subsystem: "com.biru.Artlify", category: "LiveDiffusion")

    private let renderer: CameraMetalRenderer

    private(set) var status: Status = .idle
    private(set) var smoothedSeconds: Double = 0
    private(set) var passCount: Int = 0
    var stallThresholdSeconds: Double = 2.0

    private var loopTask: Task<Void, Never>?

    init(renderer: CameraMetalRenderer) {
        self.renderer = renderer
    }

    func start(consuming session: CameraSession, settings: DiffusionBenchmark) {
        guard status != .running else { return }
        status = .running
        renderer.compositeEnabled = true

        let renderer = self.renderer
        loopTask?.cancel()
        loopTask = Task { [weak self, weak settings] in
            var lastSuccess = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                guard let self, let settings else { return }

                // Read live so model variant / compute-unit changes are picked up.
                let pipeline = settings.pipeline
                let loaded = await pipeline.isLoaded
                if !loaded {
                    self.status = .waitingForModel
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }

                guard let pb = session.latestPixelBuffer else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }

                let side = settings.inputSide
                guard let cg = PixelBufferToCGImage.makeCGImage(
                    from: pb,
                    resizedTo: CGSize(width: side, height: side)
                ) else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }

                let prompt = settings.effectivePrompt
                let steps = settings.stepCount
                let strength = settings.strength

                do {
                    let result = try await pipeline.generate(
                        prompt: prompt,
                        startingImage: cg,
                        strength: strength,
                        stepCount: steps
                    )
                    renderer.submitStylized(result.image)

                    self.passCount &+= 1
                    if self.smoothedSeconds == 0 {
                        self.smoothedSeconds = result.stats.totalSeconds
                    } else {
                        self.smoothedSeconds = 0.7 * self.smoothedSeconds
                                             + 0.3 * result.stats.totalSeconds
                    }
                    lastSuccess = CFAbsoluteTimeGetCurrent()
                    if self.status != .running {
                        self.status = .running
                    }
                } catch {
                    self.log.error("Live pass failed: \(error.localizedDescription, privacy: .public)")
                    self.status = .failed(error.localizedDescription)
                    try? await Task.sleep(for: .milliseconds(250))
                }

                if CFAbsoluteTimeGetCurrent() - lastSuccess > self.stallThresholdSeconds {
                    self.status = .stalled(reason: "No stylized frame in \(Int(self.stallThresholdSeconds))s")
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        renderer.compositeEnabled = false
        renderer.clearStylized()
        status = .idle
        smoothedSeconds = 0
        passCount = 0
    }
}
