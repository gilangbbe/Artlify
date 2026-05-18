//
//  MusicKitPlayer.swift
//  Artlify / AppShell — `particles` branch
//
//  Karaoke phase 2 — Apple Music playback driver.
//
//  Wraps the global `ApplicationMusicPlayer.shared` so the rest of
//  the app sees a small, observable surface: `play(song:) async`,
//  `pause()`, `resume()`, `stop()`, plus published `currentTime /
//  duration / isPlaying / lastError`. The HUD's karaoke timeline
//  reads `currentTime` directly, so lyrics stay locked to whatever
//  the Apple Music daemon is actually playing back.
//
//  Why a poll timer instead of KVO:
//  `ApplicationMusicPlayer.PlaybackTime` is published, but the
//  player's `playbackTime` is a plain Double we'd have to observe
//  through key-paths anyway. A 10 Hz poll on the main actor is
//  cheap and gives us a single place to also derive `isPlaying`
//  from `state.playbackStatus`. The karaoke overlay re-paints at
//  60 Hz against `karaoke.currentTime`, so the 10 Hz poll is plenty
//  of resolution for line transitions.
//

import Foundation
import MusicKit
import Observation
import OSLog

@Observable
@MainActor
public final class MusicKitPlayer {

    private let log = Logger(subsystem: "com.biru.Artlify",
                             category: "MusicKitPlayer")

    // MARK: - Published state

    public private(set) var currentSongTitle: String = ""
    public private(set) var currentSongArtist: String = ""
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isPlaying: Bool = false
    /// Non-nil when the user has picked an Apple Music song. The
    /// HUD branches its timeline drive on this being set, the same
    /// way it does for `AudioFilePlayer.fileURL`.
    public private(set) var isActive: Bool = false
    public private(set) var lastError: String?

    // MARK: - Private

    private let player = ApplicationMusicPlayer.shared
    private var pollTask: Task<Void, Never>?

    public init() {}

    // No explicit deinit: the poll task captures `weak self` and exits
    // on the next 100 ms tick when self is gone, which is good enough
    // (and saves us fighting `@MainActor`-isolated `deinit` rules).

    // MARK: - Transport

    /// Queue + play a catalog `Song`. Replaces whatever the user had
    /// queued previously. Authorization is the caller's job (done by
    /// `MusicKitClient.ensureAuthorized()` before search).
    public func play(song: Song) async {
        lastError = nil
        currentSongTitle = song.title
        currentSongArtist = song.artistName
        // MusicKit reports duration in seconds; some catalog entries
        // omit it (rare), so fall back to 0 and let the karaoke row
        // keep its slider grey until we see the first poll come in
        // with a non-zero value (which we then mirror onto duration).
        duration = song.duration ?? 0
        isActive = true
        player.queue = [song]
        do {
            try await player.play()
            isPlaying = true
            startPolling()
            log.info("MusicKitPlayer playing \(song.title, privacy: .public) — \(song.artistName, privacy: .public)")
        } catch {
            isPlaying = false
            isActive = false
            lastError = error.localizedDescription
            log.error("MusicKitPlayer play failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func pause() {
        guard isActive else { return }
        player.pause()
        isPlaying = false
    }

    public func resume() {
        guard isActive else { return }
        Task { @MainActor in
            do {
                try await player.play()
                isPlaying = true
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        player.stop()
        // `stop()` doesn't drop the queue — clear it so the next
        // `play()` doesn't resume the previous song.
        player.queue = []
        isPlaying = false
        isActive = false
        currentTime = 0
        duration = 0
        currentSongTitle = ""
        currentSongArtist = ""
    }

    public func seek(to seconds: TimeInterval) {
        guard isActive else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.playbackTime = clamped
        currentTime = clamped
    }

    // MARK: - Poll loop

    /// 10 Hz poll of `player.playbackTime` + `state.playbackStatus`.
    /// We intentionally don't observe via Combine — the API surface
    /// is small enough that this single loop is easier to reason
    /// about than scattered `objectWillChange` subscriptions.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.currentTime = self.player.playbackTime
                let status = self.player.state.playbackStatus
                let nowPlaying = (status == .playing)
                if nowPlaying != self.isPlaying {
                    self.isPlaying = nowPlaying
                }
                // Track-ended: the daemon flips status to `.stopped`
                // when the song drains. Treat that as "park at the
                // end of the track" so the karaoke overlay holds the
                // last lyric rather than snapping back to t=0.
                if status == .stopped, self.isActive, self.duration > 0,
                   self.currentTime >= self.duration - 0.1 {
                    self.currentTime = self.duration
                    self.isPlaying = false
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
        }
    }
}
