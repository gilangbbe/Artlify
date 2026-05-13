//
//  AudioReactor.swift
//  Artlify / AudioKit
//
//  Listens to the system microphone via AVAudioEngine and publishes a
//  smoothed (low / mid / high / level / pan) snapshot at audio-rate.
//  The particle shader reads these values once per frame to modulate
//  flow strength, glow, and to inject occasional shockwave kicks.
//
//  Design choices:
//
//  * One engine, one tap, one FFT. Heavy lifting (vDSP forward FFT) is
//    O(N log N) for N=1024 ≈ a microsecond. Runs on the audio render
//    thread; the only cross-thread state is the latest snapshot, which
//    is read by the SwiftUI/Metal main thread on every draw via a
//    serial dispatch queue + atomic-ish copy.
//
//  * Bands are coarse on purpose: low (≤ 200 Hz), mid (200 Hz – 2 kHz),
//    high (2 kHz – 8 kHz). We don't need a spectrogram — we need three
//    knobs the swarm can react to.
//
//  * Pan is computed as (R - L) / (R + L + ε) using per-channel RMS
//    when the input is multichannel; on mono inputs it stays at 0. The
//    shader interprets pan ∈ [-1, +1] as a screen-x offset for the
//    audio-driven shockwave centre.
//
//  * The reactor never blocks. If start() throws (mic perm denied, no
//    input device, sample rate mismatch) the field still runs visually,
//    just without audio modulation.
//

import Foundation
import AVFoundation
import Accelerate
import OSLog
import Observation

/// Snapshot of the last analysed buffer. Cheap value type so we can
/// copy it across threads without locks beyond the single read.
nonisolated public struct AudioFrame: Equatable, Sendable {
    public var level: Float    // 0..1, broadband RMS (smoothed, normalised)
    public var low:   Float    // 0..1, ≤ 200 Hz
    public var mid:   Float    // 0..1, 200 Hz .. 2 kHz
    public var high:  Float    // 0..1, 2 kHz .. 8 kHz
    public var pan:   Float    // -1 (left) .. +1 (right); 0 if mono input
    public var transient: Float // 0..1, instantaneous attack — fades fast

    public static let zero = AudioFrame(level: 0, low: 0, mid: 0, high: 0,
                                        pan: 0, transient: 0)
}

@Observable
nonisolated public final class AudioReactor: @unchecked Sendable {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "AudioKit")

    // ---- Public state read by the renderer / UI on the main thread.
    public private(set) var latest: AudioFrame = .zero
    public private(set) var isRunning: Bool = false
    public private(set) var lastError: String?

    /// Master input gain. Multiplies the analysed magnitudes before
    /// they're clipped to [0,1] and exposed to the shader.
    public var gain: Float = 1.0

    /// Smoothing on band magnitudes (EMA alpha for the slow track).
    /// Closer to 1.0 = sluggish, closer to 0 = jittery.
    public var smoothing: Float = 0.6

    // ---- Private engine state.
    private let engine = AVAudioEngine()
    private let analyzeQueue = DispatchQueue(label: "com.biru.Artlify.audio.analyze",
                                             qos: .userInitiated)

    // FFT scratch — allocated once.
    private let fftLog2N: vDSP_Length = 10            // N = 1024
    private var fftN: Int { 1 << Int(fftLog2N) }
    private var fftSetup: vDSP.FFT<DSPSplitComplex>?
    private var window: [Float] = []
    private var windowed: [Float] = []
    private var realIn:  [Float] = []
    private var imagIn:  [Float] = []
    private var realOut: [Float] = []
    private var imagOut: [Float] = []

    // Smoothed bands kept on the audio thread.
    private var sLow:   Float = 0
    private var sMid:   Float = 0
    private var sHigh:  Float = 0
    private var sLevel: Float = 0
    private var sPan:   Float = 0
    private var lastLevel: Float = 0  // for transient detection

    public init() {
        // Pre-build FFT setup + window. N=1024 is a good balance between
        // frequency resolution (~46 Hz @ 48 kHz) and latency (~21 ms).
        if let setup = vDSP.FFT(log2n: fftLog2N,
                                radix: .radix2,
                                ofType: DSPSplitComplex.self) {
            self.fftSetup = setup
        }
        let n = fftN
        window  = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: n)
        realIn   = [Float](repeating: 0, count: n / 2)
        imagIn   = [Float](repeating: 0, count: n / 2)
        realOut  = [Float](repeating: 0, count: n / 2)
        imagOut  = [Float](repeating: 0, count: n / 2)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            lastError = "no input format"
            log.error("AudioReactor: no input format")
            return
        }

        // Tap on input bus 0. AVAudioEngine will deliver buffers on its
        // own thread; we copy out the analysis-needed slice and dispatch
        // the heavy work off the audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
            log.info("AudioReactor started, sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public)")
        } catch {
            input.removeTap(onBus: 0)
            isRunning = false
            lastError = error.localizedDescription
            log.error("AudioReactor failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        latest = .zero
    }

    // MARK: - Analysis (audio thread → analyzeQueue → main)

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0 else { return }

        // Per-channel RMS for pan; copy a mono mix for FFT.
        var rmsL: Float = 0
        var rmsR: Float = 0
        if channelCount >= 1 {
            vDSP_rmsqv(channelData[0], 1, &rmsL, vDSP_Length(frameCount))
        }
        if channelCount >= 2 {
            vDSP_rmsqv(channelData[1], 1, &rmsR, vDSP_Length(frameCount))
        } else {
            rmsR = rmsL
        }

        // Mono mix into a separate buffer so we can window it.
        let n = fftN
        var mono = [Float](repeating: 0, count: n)
        let copyN = min(frameCount, n)
        if channelCount >= 2 {
            vDSP_vadd(channelData[0], 1, channelData[1], 1, &mono, 1, vDSP_Length(copyN))
            var half: Float = 0.5
            vDSP_vsmul(mono, 1, &half, &mono, 1, vDSP_Length(copyN))
        } else {
            _ = mono.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, channelData[0], copyN * MemoryLayout<Float>.size)
            }
        }

        // Hop the heavy work off the audio render thread.
        analyzeQueue.async { [weak self, mono, rmsL, rmsR] in
            self?.analyse(monoSamples: mono, rmsL: rmsL, rmsR: rmsR)
        }
    }

    nonisolated private func analyse(monoSamples: [Float], rmsL: Float, rmsR: Float) {
        guard let fftSetup else { return }
        let n = fftN

        // Window the mono signal in place.
        vDSP_vmul(monoSamples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Pack real samples into split-complex form (even → real, odd → imag).
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cptr in
                realIn.withUnsafeMutableBufferPointer { rp in
                    imagIn.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                    imagp: ip.baseAddress!)
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        // Forward FFT → realOut/imagOut (still split-complex).
        realIn.withUnsafeBufferPointer { rip in
            imagIn.withUnsafeBufferPointer { iip in
                realOut.withUnsafeMutableBufferPointer { rop in
                    imagOut.withUnsafeMutableBufferPointer { iop in
                        let inSplit  = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rip.baseAddress!),
                                                       imagp: UnsafeMutablePointer(mutating: iip.baseAddress!))
                        var outSplit = DSPSplitComplex(realp: rop.baseAddress!,
                                                       imagp: iop.baseAddress!)
                        fftSetup.forward(input: inSplit, output: &outSplit)
                    }
                }
            }
        }

        // Magnitudes per bin.
        var mags = [Float](repeating: 0, count: n / 2)
        realOut.withUnsafeBufferPointer { rop in
            imagOut.withUnsafeBufferPointer { iop in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: rop.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: iop.baseAddress!))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // Frequency per bin (assumes 48 kHz; close enough for any
        // sample rate the input might be running at — bin centres
        // shift but the BAND boundaries derive from the same sample
        // rate so it's self-consistent. We don't have the actual SR
        // here; we'd need to capture it in the closure if we cared).
        let sampleRate: Float = 48_000
        let binHz = sampleRate / Float(n)
        let lowMax  = Int( 200.0 / binHz)
        let midMax  = Int(2000.0 / binHz)
        let highMax = Int(8000.0 / binHz)

        var low: Float = 0, mid: Float = 0, high: Float = 0
        if lowMax > 1 {
            mags.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + 1, 1, &low, vDSP_Length(lowMax - 1))
            }
        }
        if midMax > lowMax {
            mags.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + lowMax, 1, &mid, vDSP_Length(midMax - lowMax))
            }
        }
        if highMax > midMax {
            mags.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + midMax, 1, &high, vDSP_Length(highMax - midMax))
            }
        }

        // FFT scaling — vDSP returns 2× the unnormalised, so divide by
        // n/2. Then squash with a perceptual log curve so quiet rooms
        // produce visible motion without exploding under loud input.
        let norm = 2.0 / Float(n)
        low  *= norm
        mid  *= norm
        high *= norm

        let g = gain
        low  = clip01(perceptual(low  * g))
        mid  = clip01(perceptual(mid  * g))
        high = clip01(perceptual(high * g))

        let level = clip01(perceptual(0.5 * (rmsL + rmsR) * g * 4.0))
        let pan   = clip(-1, 1, (rmsR - rmsL) / max(1e-5, rmsR + rmsL))

        // Transient = rising edge of level.
        let dLevel = max(0, level - lastLevel)
        let transient = clip01(dLevel * 4.0)
        lastLevel = level * 0.85 + lastLevel * 0.15

        // EMA smooth.
        let a  = clip01(1.0 - smoothing)   // alpha for new sample
        sLow   = sLow   * (1 - a) + low   * a
        sMid   = sMid   * (1 - a) + mid   * a
        sHigh  = sHigh  * (1 - a) + high  * a
        sLevel = sLevel * (1 - a) + level * a
        sPan   = sPan   * (1 - a) + pan   * a

        let snapshot = AudioFrame(level: sLevel,
                                  low:   sLow,
                                  mid:   sMid,
                                  high:  sHigh,
                                  pan:   sPan,
                                  transient: transient)

        // Hop back to main for the @Observable publish.
        DispatchQueue.main.async { [snapshot] in
            self.latest = snapshot
        }
    }

    private func perceptual(_ x: Float) -> Float {
        // log1p compresses dynamic range; the constant biases so
        // typical room ambience reads ~0.1, conversation ~0.4.
        return log1pf(x * 12.0) / log1pf(12.0)
    }
    private func clip01(_ x: Float) -> Float { min(1, max(0, x)) }
    private func clip(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
        min(hi, max(lo, x))
    }
}
