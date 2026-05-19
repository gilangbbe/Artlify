//
//  VisionSession.swift
//  Artlify / AppShell
//
//  Glue object that runs VisionProcessor at a throttled cadence on
//  whatever the latest camera frame happens to be. Latest-frame-wins:
//  if we're still processing frame N when N+1 arrives, N+1 just
//  overwrites the buffer and frame N's result is what the UI sees
//  briefly until N+2 lands.
//
//  The cadence cap (default ~15 Hz) protects thermals and leaves room
//  on the GPU/ANE for the diffusion pipeline (M3). Vision is much
//  cheaper than diffusion; this is the right side of the budget to
//  starve.
//

import Foundation
import Observation
import OSLog
import CoreVideo

@MainActor
@Observable
final class VisionSession {

    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    private let log = Logger(subsystem: "com.biru.Artlify", category: "AppShell")
    private let processor = VisionProcessor()

    /// Target processing cadence. Default 15 Hz.
    var targetHz: Double = 15.0

    private(set) var status: Status = .idle
    private(set) var latestFrame: VisionFrame?
    /// Smoothed processing-time, exponential moving average in seconds.
    private(set) var smoothedProcessingSeconds: Double = 0
    /// Monotonic count of successful processing passes since `start`.
    private(set) var passCount: Int = 0

    private var loopTask: Task<Void, Never>?

    func start(consuming session: CameraSession) {
        guard status != .running else { return }
        status = .running
        let processor = self.processor
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var lastTimestamp: CFAbsoluteTime = 0
            while !Task.isCancelled {
                guard let self else { return }
                let interval = 1.0 / max(1.0, self.targetHz)

                guard let pb = session.latestPixelBuffer else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }

                // Skip if this exact pixel-buffer pointer has already been
                // processed (no new frame arrived since last pass).
                let pointerStamp = CFAbsoluteTimeGetCurrent()
                if pointerStamp - lastTimestamp < interval {
                    try? await Task.sleep(for: .milliseconds(Int(interval * 1000.0 / 2.0)))
                    continue
                }
                lastTimestamp = pointerStamp

                do {
                    let frame = try await processor.process(pb)
                    self.latestFrame = frame
                    self.passCount &+= 1
                    // EMA, alpha = 0.2
                    if self.smoothedProcessingSeconds == 0 {
                        self.smoothedProcessingSeconds = frame.processingSeconds
                    } else {
                        self.smoothedProcessingSeconds =
                            0.8 * self.smoothedProcessingSeconds +
                            0.2 * frame.processingSeconds
                    }
                } catch {
                    self.status = .failed(error.localizedDescription)
                    self.log.error("vision pass failed: \(error.localizedDescription, privacy: .public)")
                    // Don't busy-loop on a persistent failure.
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        status = .idle
        latestFrame = nil
        smoothedProcessingSeconds = 0
        passCount = 0
    }

    /// Toggle hand-pose detection on the underlying processor. The
    /// processor is an actor so the flip happens asynchronously;
    /// callers shouldn't expect the next single frame to reflect it.
    func setHandPoseEnabled(_ enabled: Bool) {
        let processor = self.processor
        Task { await processor.setHandPoseEnabled(enabled) }
    }
}
