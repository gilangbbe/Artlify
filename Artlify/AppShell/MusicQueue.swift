//
//  MusicQueue.swift
//  Artlify / AppShell — `particles` branch
//
//  Lightweight, observable playlist used by the production HUD's
//  Music menu. Models the user's "play this then that" intent; the
//  actual playback is still owned by `AudioFilePlayer` (local files)
//  and `MusicKitPlayer` (Apple Music catalog), this queue just
//  remembers what to play next and tracks the cursor.
//
//  Auto-advance is wired in `ContentView`:
//    - `AudioFilePlayer.onFinished` → `playNextInQueue()`
//    - `MusicKitPlayer.onFinished`  → `playNextInQueue()`
//
//  `playNextInQueue()` calls `MusicQueue.advance()` and dispatches
//  the returned `MusicQueueItem` to whichever player can handle its
//  `source`. End-of-queue is a normal nil return — the HUD just
//  parks at the last track.
//

import Foundation
import Observation
import MusicKit

/// One playable entry in the queue. UUID-identified so SwiftUI's
/// `ForEach`/`List` reorder stays stable across `move` operations,
/// and so two enqueued copies of the same song are distinct rows.
struct MusicQueueItem: Identifiable, Hashable {

    let id: UUID
    var title: String
    var artist: String?
    var duration: TimeInterval?
    var source: Source

    enum Source: Hashable {
        /// Local audio file (mp3/m4a/wav/aiff/aac/flac). Played via
        /// `AudioFilePlayer`.
        case localFile(URL)
        /// Apple Music catalog song. Played via `MusicKitPlayer`.
        case appleMusic(Song)
        /// Built-in demo LRC — no audio, karaoke timeline only. Kept
        /// in the queue so the "Sample" button slots cleanly into the
        /// same auto-advance flow as real tracks.
        case sampleLRC
    }

    init(title: String,
         artist: String? = nil,
         duration: TimeInterval? = nil,
         source: Source) {
        self.id = UUID()
        self.title = title
        self.artist = artist
        self.duration = duration
        self.source = source
    }

    /// SF Symbol used as a row icon in the music menu's queue list.
    /// Mirrors the source enum so the user can tell at a glance what
    /// each row will route to when it plays.
    var sourceIcon: String {
        switch source {
        case .localFile:  return "folder.fill"
        case .appleMusic: return "music.note"
        case .sampleLRC:  return "waveform"
        }
    }
}

/// Ordered playlist + auto-advance cursor. Lightweight: no playback,
/// no audio session, no notifications — just the data structure the
/// Music menu reads and writes. All mutation is `@MainActor`-confined
/// (the HUD's natural isolation) so SwiftUI sees consistent state.
@Observable
@MainActor
final class MusicQueue {

    /// Ordered queue, head first. SwiftUI `ForEach`es over this
    /// directly via the items' `id`.
    private(set) var items: [MusicQueueItem] = []

    /// Index of the currently-playing item, or nil when nothing in
    /// the queue is the "active" track (either nothing's playing, or
    /// the user loaded a one-off via `loadAudioFile()` before adding
    /// anything to the queue).
    private(set) var currentIndex: Int? = nil

    var current: MusicQueueItem? {
        guard let i = currentIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    /// True if `advance()` would return a non-nil item.
    var hasNext: Bool {
        let next = (currentIndex ?? -1) + 1
        return items.indices.contains(next)
    }

    /// True if `currentIndex` points to something we can rewind into.
    var hasPrevious: Bool {
        guard let i = currentIndex else { return false }
        return i > 0
    }

    // MARK: - Mutation

    func append(_ item: MusicQueueItem) {
        items.append(item)
    }

    func append(contentsOf newItems: [MusicQueueItem]) {
        items.append(contentsOf: newItems)
    }

    /// Insert immediately after the current item — "play next".
    func playNext(_ item: MusicQueueItem) {
        let insertAt = (currentIndex.map { $0 + 1 }) ?? items.count
        items.insert(item, at: min(insertAt, items.count))
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        // Keep `currentIndex` pointing at the same logical track. If
        // the removed row *was* the current one, clear it so the HUD
        // shows "nothing playing" until the user advances explicitly.
        if let cur = currentIndex {
            if index < cur {
                currentIndex = cur - 1
            } else if index == cur {
                currentIndex = nil
            }
        }
    }

    func clear() {
        items.removeAll()
        currentIndex = nil
    }

    /// Reorder one row. Used by the Music menu's up/down arrows; a
    /// full SwiftUI `.onMove` drag would also call into this.
    func move(from src: Int, to dst: Int) {
        guard items.indices.contains(src), src != dst else { return }
        let clamped = max(0, min(dst, items.count - 1))
        let it = items.remove(at: src)
        items.insert(it, at: clamped)
        // Re-anchor the cursor. Easiest correct rule: if the cursor
        // was on the moved row, follow it; otherwise re-derive from
        // before/after relationships.
        if let cur = currentIndex {
            if cur == src {
                currentIndex = clamped
            } else {
                var c = cur
                if src < c { c -= 1 }
                if clamped <= c { c += 1 }
                currentIndex = c
            }
        }
    }

    func moveUp(_ index: Int)   { move(from: index, to: index - 1) }
    func moveDown(_ index: Int) { move(from: index, to: index + 1) }

    // MARK: - Cursor

    /// Advance the cursor one step and return the new current item.
    /// Returns nil at end-of-queue (and resets `currentIndex` to nil
    /// so a subsequent `advance()` starts from the top again).
    @discardableResult
    func advance() -> MusicQueueItem? {
        let next = (currentIndex ?? -1) + 1
        guard items.indices.contains(next) else {
            currentIndex = nil
            return nil
        }
        currentIndex = next
        return items[next]
    }

    /// Step back one item. Returns nil if there's no previous row.
    @discardableResult
    func previous() -> MusicQueueItem? {
        guard let i = currentIndex, i > 0 else { return nil }
        let prev = i - 1
        currentIndex = prev
        return items[prev]
    }

    /// Jump the cursor to a specific row and return that item, so the
    /// caller can route it to the right player.
    @discardableResult
    func jump(to index: Int) -> MusicQueueItem? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return items[index]
    }
}
