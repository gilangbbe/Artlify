//
//  AudioFilePlayer.swift
//  Artlify / AudioKit — `particles` branch
//
//  Karaoke phase 2 — local file playback slice.
//
//  Plays a user-picked audio file (mp3/m4a/wav/aac/flac) through
//  the default output, exposes sample-accurate `currentTime` for
//  karaoke time-locking, AND installs a tap on the player node
//  that forwards `AVAudioPCMBuffer`s straight into `AudioReactor`
//  for analysis. The reactor's third `InputSource` (`.audioFile`)
//  is fed by this player — no microphone, no ScreenCaptureKit
//  round-trip, no permissions of any kind.
//
//  Why this matters for karaoke:
//  - With mic or system audio as source, `karaoke.currentTime`
//    advances on the wall clock and drifts against the music
//    (you sync at song-start and pray). With this player, time
//    comes from `AVAudioPlayerNode.lastRenderTime`, which is
//    locked to the audio render thread sample counter — there's
//    nothing to drift against.
//  - Pause / seek / track-end all naturally propagate to the
//    karaoke overlay because the karaoke wall-clock integrator
//    is short-circuited while this player owns the timeline.
//

import Foundation
import AVFoundation
import AppKit
import Observation
import OSLog

@Observable
nonisolated public final class AudioFilePlayer: @unchecked Sendable {

    private let log = Logger(subsystem: "com.biru.Artlify",
                             category: "AudioFilePlayer")

    // MARK: - Published state (read on main)

    public private(set) var fileURL: URL?
    /// Display name for the HUD. Empty until a file is loaded.
    public private(set) var fileName: String = ""
    public private(set) var duration: TimeInterval = 0
    /// Authoritative playback position derived from the player node's
    /// last render time + the seek offset. Updated on every tap.
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var isPlaying: Bool = false
    public private(set) var lastError: String?

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?

    /// Sample offset applied to translate node `sampleTime` into
    /// file-relative position. Reset on every seek + load.
    private var seekOffsetSamples: AVAudioFramePosition = 0

    // MARK: - Reactor hook

    /// Called on the audio thread for every tapped buffer. Wire this
    /// to `AudioReactor.ingest(buffer:)` so the analysis pipeline
    /// sees the file's audio directly (independent of what's on the
    /// speakers).
    public var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Called on the main actor when the file plays to its end so
    /// the HUD can flip `isPlaying` and the karaoke overlay can stop
    /// chasing past `duration`.
    public var onFinished: (() -> Void)?

    public init() {
        engine.attach(player)
        // Touch mainMixerNode now so AVAudioEngine performs the lazy
        // auto-connect mixer→outputNode at the *hardware* format
        // before we add our player→mixer connection. If we let this
        // happen later (after our connect call), the auto-connect can
        // pick a stale / mismatched format and produce silence on the
        // default output device.
        _ = engine.mainMixerNode
        engine.mainMixerNode.outputVolume = 1.0
    }

    // MARK: - Load / Play / Pause / Stop / Seek

    public func load(url: URL) throws {
        // Stop the previous file cleanly before swapping; otherwise
        // the in-flight scheduled buffer would keep firing the
        // completion handler after we've moved on.
        stop()

        let f = try AVAudioFile(forReading: url)
        self.file = f
        self.fileURL = url
        self.fileName = url.deletingPathExtension().lastPathComponent
        self.duration = Double(f.length) / f.processingFormat.sampleRate
        self.seekOffsetSamples = 0
        self.currentTime = 0
        self.lastError = nil

        // (Re)connect player to mainMixer at the file's processing
        // format. Disconnecting first avoids "format mismatch" if
        // we're loading a track with different sample rate / channel
        // count than the previous one.
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode,
                       format: f.processingFormat)

        // Install the analysis tap on the player node. The tap fires
        // even when the player is paused (no it doesn't — taps only
        // produce data when audio is flowing), so position updates
        // come naturally from the same callback we use for analysis.
        player.removeTap(onBus: 0)
        player.installTap(onBus: 0,
                          bufferSize: 1024,
                          format: f.processingFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.handleTap(buffer: buffer, time: time)
        }

        log.info("AudioFilePlayer loaded \(url.lastPathComponent, privacy: .public) — \(self.duration, privacy: .public) s, sr=\(f.processingFormat.sampleRate, privacy: .public)")
    }

    public func play() {
        guard let f = file else { return }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            // Schedule from the current seek offset to end-of-file.
            let remaining = AVAudioFrameCount(max(0, f.length - seekOffsetSamples))
            guard remaining > 0 else {
                // Already at the end — nothing to schedule. Treat as
                // immediate finish.
                DispatchQueue.main.async { [weak self] in
                    self?.onFinished?()
                }
                return
            }
            player.scheduleSegment(
                f,
                startingFrame: seekOffsetSamples,
                frameCount: remaining,
                at: nil
            ) { [weak self] in
                // Fires from a CoreAudio thread when playback drains.
                // Only flip state if the user didn't seek/stop us in
                // the meantime — guard by comparing the player's
                // playing flag on main.
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isPlaying {
                        self.isPlaying = false
                        self.currentTime = self.duration
                        self.onFinished?()
                    }
                }
            }
            player.play()
            isPlaying = true
        } catch {
            isPlaying = false
            lastError = error.localizedDescription
            log.error("AudioFilePlayer.play failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    public func stop() {
        if player.isPlaying { player.stop() }
        player.removeTap(onBus: 0)
        // Deliberately leave `engine` running. Stopping + restarting
        // the engine between tracks tears down the mixer→output
        // connection on some macOS versions and the next `play()`
        // produces silence. The engine is cheap to leave idle —
        // there's no audio flowing when the player is stopped.
        isPlaying = false
    }

    /// Seek to an absolute file position. If currently playing, picks
    /// up playback from there; if paused, just updates the position
    /// and the next `play()` will start from this offset.
    public func seek(to seconds: TimeInterval) {
        guard let f = file else { return }
        let clamped = max(0, min(seconds, duration))
        let wasPlaying = isPlaying
        if player.isPlaying { player.stop() }
        seekOffsetSamples = AVAudioFramePosition(clamped * f.processingFormat.sampleRate)
        currentTime = clamped
        if wasPlaying { play() }
    }

    // MARK: - Tap → reactor + currentTime update

    private func handleTap(buffer: AVAudioPCMBuffer,
                           time: AVAudioTime) {
        // Forward to the reactor (analysis pipeline).
        onAudioBuffer?(buffer)

        // Derive currentTime from the node's playerTime conversion.
        // `lastRenderTime` -> node playerTime gives us the sample
        // index *within this scheduling*, which we offset by where
        // the user last seeked from.
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let sr = playerTime.sampleRate
            guard sr > 0 else { return }
            let pos = Double(seekOffsetSamples + playerTime.sampleTime) / sr
            let clamped = max(0, min(pos, duration))
            DispatchQueue.main.async { [weak self] in
                self?.currentTime = clamped
            }
        }
    }
}

// MARK: - File-picker convenience

public extension AudioFilePlayer {

    /// Pop an `NSOpenPanel` for common audio types. Returns the URL
    /// the user picked, or nil if they cancelled.
    @MainActor
    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .mp3, .mpeg4Audio, .wav, .aiff, .audio
        ]
        panel.prompt = "Load track"
        panel.title = "Choose an audio file"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
