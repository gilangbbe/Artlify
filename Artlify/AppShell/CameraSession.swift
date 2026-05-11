//
//  CameraSession.swift
//  Artlify / AppShell
//
//  Glue object owned by the SwiftUI view. Holds the renderer + capture,
//  pumps frames from the AsyncStream into the renderer, and exposes
//  user-facing status.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CameraSession {

    enum Status: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private let log = Logger(subsystem: "com.biru.Artlify", category: "AppShell")

    let renderer: CameraMetalRenderer
    private let capture = CameraCapture()
    private var pumpTask: Task<Void, Never>?

    private(set) var status: Status = .idle
    private(set) var firstFrameLatencyMS: Double?
    private var startedAt: CFAbsoluteTime = 0

    init() {
        do {
            self.renderer = try CameraMetalRenderer()
        } catch {
            // If Metal is unavailable on this machine the app cannot work at all.
            // Crashing here gives the developer a clear stack instead of a blank screen.
            fatalError("Failed to create Metal renderer: \(error)")
        }
    }

    func start() {
        guard status == .idle else { return }
        status = .starting
        startedAt = CFAbsoluteTimeGetCurrent()

        pumpTask?.cancel()
        // The Task inherits @MainActor from the enclosing context. The
        // capture API is nonisolated; AsyncStream<CVPixelBuffer> crosses
        // actor boundaries cleanly via `await`.
        pumpTask = Task { [capture, renderer] in
            do {
                try await capture.start()
            } catch {
                self.status = .failed(error.localizedDescription)
                return
            }
            self.status = .running
            for await pb in capture.frames() {
                if Task.isCancelled { break }
                self.recordFirstFrameIfNeeded()
                renderer.submit(pb)
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        capture.stop()
        status = .idle
        firstFrameLatencyMS = nil
    }

    private func recordFirstFrameIfNeeded() {
        guard firstFrameLatencyMS == nil else { return }
        firstFrameLatencyMS = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
        log.info("First camera frame after \(self.firstFrameLatencyMS ?? 0, format: .fixed(precision: 0)) ms")
    }
}
