//
//  AppleMusicBrowser.swift
//  Artlify / GameKit — universe-tune branch
//
//  Full-screen search UI for Apple Music catalog songs.
//  Also contains TileSong.fromAppleMusic(_:) which generates a
//  deterministic tile pattern from song metadata (title hash + duration).
//
//  Requires: com.apple.developer.musickit entitlement + macOS authorization.
//

import SwiftUI
import MusicKit

// MARK: - TileSong factory

extension TileSong {
    /// Generates a TileSong whose tile pattern is seeded from the song's
    /// title + artist hash, so the same song always produces the same layout.
    /// BPM defaults to 120 — MusicKit's public API does not expose tempo.
    static func fromAppleMusic(_ handle: AppleMusicHandle) -> TileSong {
        let bpm: Double = 120.0
        let beatDur = 60.0 / bpm
        let totalBeats: Double
        if let dur = handle.duration, dur > 0 {
            totalBeats = max(32.0, (dur / beatDur).rounded(.down))
        } else {
            totalBeats = 128.0
        }

        var rng = AMSeededRandom(seed: UInt64(bitPattern: Int64(
            handle.title.hashValue &+ handle.artistName.hashValue
        )))

        var events: [NoteEvent] = []
        var beat = 0.0
        let durChoices: [Double] = [0.5, 1.0, 1.0, 1.0, 1.5, 2.0]
        while beat < totalBeats - 1.5 {
            let lane    = Int(rng.next() % 8)
            let noteDur = durChoices[Int(rng.next() % UInt64(durChoices.count))]
            events.append(NoteEvent(beat: beat, lane: lane, duration: noteDur))
            // Gap: 0.5–1.5 beats between tile start times
            beat += 0.5 + Double(rng.next() % 4) * 0.25
        }

        // 8 hues evenly spaced on the colour wheel, rotated by title hash.
        let baseHue = Double((handle.title.hashValue ^ handle.artistName.hashValue) & 0xFF) / 255.0
        let colors: [Color] = (0..<8).map { i in
            let h = (baseHue + Double(i) / 8.0).truncatingRemainder(dividingBy: 1.0)
            return Color(hue: h, saturation: 0.80, brightness: 1.0)
        }

        return TileSong(
            title: handle.title,
            composer: handle.artistName,
            bpm: bpm,
            events: events.sorted { $0.beat < $1.beat },
            laneNotes: [60, 62, 64, 65, 67, 69, 71, 72], // C major scale — muted in Apple Music mode
            laneColors: colors,
            appleMusicHandle: handle
        )
    }
}

// MARK: - LCG (local to this file — not exposed)

private struct AMSeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}

// MARK: - Browser view

@MainActor
struct AppleMusicBrowser: View {
    let onSelect: (TileSong) -> Void
    let onCancel: () -> Void

    @State private var authStatus: MusicAuthorization.Status = .notDetermined
    @State private var query: String = ""
    @State private var results: [Song] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var hovered: String? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 24) {
                header

                switch authStatus {
                case .authorized:
                    searchContent
                case .denied, .restricted:
                    accessDeniedView
                default:
                    requestingView
                }

                Button("← back") { onCancel() }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
                    .buttonStyle(.plain)
            }
            .padding(40)
        }
        .task {
            authStatus = MusicAuthorization.currentStatus
            if authStatus == .notDetermined {
                authStatus = await MusicAuthorization.request()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("universe tune")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.40))
                .tracking(6)
            Text("apple music")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .purple, .cyan],
                                   startPoint: .leading, endPoint: .trailing)
                )
        }
    }

    // MARK: - Auth states

    private var requestingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white)
            Text("requesting Apple Music access…")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var accessDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.pink.opacity(0.7))
            Text("Apple Music access denied")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text("Enable in System Settings → Privacy & Security\n→ Media & Apple Music")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Search content

    @ViewBuilder
    private var searchContent: some View {
        VStack(spacing: 16) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.4))
                TextField("search songs…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white)
                    .onChange(of: query) { _, newVal in scheduleSearch(newVal) }
                if isSearching {
                    ProgressView().scaleEffect(0.6).tint(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15), lineWidth: 1))
            .frame(maxWidth: 500)

            if let err = searchError {
                Text(err)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            if results.isEmpty && !isSearching {
                Text(query.isEmpty ? "type a song or artist name" : "no results")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxHeight: 220)
            } else if !results.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { song in
                            resultRow(song)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 500, maxHeight: 320)
            }
        }
    }

    // MARK: - Result row

    @ViewBuilder
    private func resultRow(_ song: Song) -> some View {
        let isHov    = hovered == song.id.rawValue
        let baseHue  = Double((song.title.hashValue ^ song.artistName.hashValue) & 0xFF) / 255.0
        let accent   = Color(hue: baseHue, saturation: 0.80, brightness: 1.0)

        Button {
            let handle = AppleMusicHandle(
                musicItemID: song.id.rawValue,
                title: song.title,
                artistName: song.artistName,
                duration: song.duration
            )
            onSelect(TileSong.fromAppleMusic(handle))
        } label: {
            HStack(spacing: 12) {
                // Lane-colour preview strips
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { i in
                        let h = (baseHue + Double(i) / 8.0).truncatingRemainder(dividingBy: 1.0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hue: h, saturation: 0.80, brightness: 1.0))
                            .frame(width: 3, height: 20)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()

                if let dur = song.duration {
                    Text(formatDuration(dur))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Text(isHov ? "▶" : "")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(width: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isHov ? 0.07 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(isHov ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? song.id.rawValue : nil }
    }

    // MARK: - Search

    private func scheduleSearch(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ term: String) async {
        isSearching = true
        searchError = nil
        do {
            var req = MusicCatalogSearchRequest(term: term, types: [Song.self])
            req.limit = 25
            let resp = try await req.response()
            results = Array(resp.songs)
        } catch {
            searchError = "Search failed: \(error.localizedDescription)"
            results = []
        }
        isSearching = false
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
