//
//  AppleMusicBrowser.swift
//  Artlify / GameKit — universe-tune branch
//
//  Full-screen search UI for Apple Music catalog songs.
//  TileSong.fromAppleMusic(_:) generates an 8th-note beat-grid tile pattern
//  from the song's real BPM and key signature, fetched from the Apple Music
//  REST catalog API via MusicDataRequest (auth handled automatically).
//
//  Requires: com.apple.developer.musickit entitlement + macOS authorization.
//

import SwiftUI
import MusicKit

// MARK: - TileSong factory

extension TileSong {
    /// Builds a TileSong from an Apple Music catalog track.
    /// Uses real BPM and key signature when available from extended attributes;
    /// falls back to 120 BPM / C major when the catalog omits them.
    /// Tile pattern is an 8th-note beat grid seeded from title+artist hash so
    /// the same song always produces the same layout.
    static func fromAppleMusic(_ handle: AppleMusicHandle) -> TileSong {
        let bpm     = handle.tempo ?? 120.0
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

        // 8th-note beat grid.  Each step consumes 3 RNG values unconditionally
        // so lane/duration choices stay deterministic regardless of which steps
        // happen to spawn tiles.
        let stepsPerBeat    = 2
        let totalSteps      = Int(totalBeats) * stepsPerBeat
        let stepSize        = 1.0 / Double(stepsPerBeat)
        let durChoices: [Double] = [0.5, 1.0, 1.0, 1.5]
        var events: [NoteEvent] = []
        // Minimum gap between any two tiles so they never appear at the same
        // horizontal level — guarantees the player can always catch one before
        // the next arrives.  1 beat gives ~0.22 UV separation at the slowest
        // supported tempo (60 BPM) and is clearly visible at any BPM.
        let minBeatGap: Double = 1.0
        var lastSpawnedBeat: Double = -minBeatGap

        for step in 0..<totalSteps {
            let currentBeat = Double(step) * stepSize
            let beatInBar = step % (stepsPerBeat * 4)
            // Density out of 8: strong beats ~87 %, backbeats ~62 %, offbeats ~37 %
            let threshold: UInt64
            if beatInBar == 0 || beatInBar == stepsPerBeat * 2 {
                threshold = 7
            } else if beatInBar % stepsPerBeat == 0 {
                threshold = 5
            } else {
                threshold = 3
            }
            let roll    = rng.next() % 8
            let lane    = Int(rng.next() % 8)
            let noteDur = durChoices[Int(rng.next() % UInt64(durChoices.count))]
            if roll < threshold && currentBeat >= lastSpawnedBeat + minBeatGap {
                events.append(NoteEvent(beat: currentBeat,
                                        lane: lane, duration: noteDur))
                lastSpawnedBeat = currentBeat
            }
        }

        // 8 hues evenly spaced on the colour wheel, rotated by title hash.
        let baseHue = Double((handle.title.hashValue ^ handle.artistName.hashValue) & 0xFF) / 255.0
        let colors: [Color] = (0..<8).map { i in
            let h = (baseHue + Double(i) / 8.0).truncatingRemainder(dividingBy: 1.0)
            return Color(hue: h, saturation: 0.80, brightness: 1.0)
        }

        return TileSong(
            title:            handle.title,
            composer:         handle.artistName,
            bpm:              bpm,
            events:           events.sorted { $0.beat < $1.beat },
            laneNotes:        midiScale(forKeySignature: handle.keySignature),
            laneColors:       colors,
            appleMusicHandle: handle
        )
    }

    // MARK: Scale / key helpers

    /// Returns 8 MIDI notes spanning one octave of the scale implied by
    /// `key` (e.g. "C", "F#m", "Bb", "A Minor").  Falls back to C major.
    static func midiScale(forKeySignature key: String?) -> [UInt8] {
        guard let key = key?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            return [60, 62, 64, 65, 67, 69, 71, 72] // C major
        }
        let lower   = key.lowercased()
        let isMinor = lower.hasSuffix("m") || lower.contains("minor")
        var rootStr: String
        if lower.contains("minor") {
            rootStr = key.replacingOccurrences(of: "minor", with: "", options: .caseInsensitive)
        } else if lower.contains("major") {
            rootStr = key.replacingOccurrences(of: "major", with: "", options: .caseInsensitive)
        } else if isMinor {
            rootStr = String(key.dropLast()) // strip trailing "m"
        } else {
            rootStr = key
        }
        rootStr = rootStr.trimmingCharacters(in: .whitespaces)
        let root      = midiRoot(rootStr)
        let intervals: [UInt8] = isMinor
            ? [0, 2, 3, 5, 7,  8, 10, 12] // natural minor
            : [0, 2, 4, 5, 7,  9, 11, 12] // major
        return intervals.map { UInt8(clamping: Int(root) + Int($0)) }
    }

    private static func midiRoot(_ name: String) -> UInt8 {
        switch name.uppercased()
            .replacingOccurrences(of: "♭", with: "B")
            .replacingOccurrences(of: "♯", with: "#") {
        case "C":         return 60
        case "C#", "DB":  return 61
        case "D":         return 62
        case "D#", "EB":  return 63
        case "E":         return 64
        case "F":         return 65
        case "F#", "GB":  return 66
        case "G":         return 67
        case "G#", "AB":  return 68
        case "A":         return 69
        case "A#", "BB":  return 70
        case "B":         return 71
        default:          return 60
        }
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
    @State private var loadingSongID: String? = nil

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
            Task { await selectSong(song) }
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

                Group {
                    if loadingSongID == song.id.rawValue {
                        ProgressView().scaleEffect(0.6).tint(accent)
                    } else {
                        Text(isHov ? "▶" : "")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isHov ? 0.07 : 0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(isHov ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(loadingSongID != nil)
        .onHover { hovered = $0 ? song.id.rawValue : nil }
    }

    // MARK: - Song selection

    private func selectSong(_ song: Song) async {
        loadingSongID = song.id.rawValue
        defer { loadingSongID = nil }

        var fetchedTempo: Double? = nil
        var fetchedKey: String?   = nil

        if let (t, k) = try? await fetchExtendedAttributes(songID: song.id.rawValue) {
            fetchedTempo = t
            fetchedKey   = k
        }

        let handle = AppleMusicHandle(
            musicItemID:  song.id.rawValue,
            title:        song.title,
            artistName:   song.artistName,
            duration:     song.duration,
            tempo:        fetchedTempo,
            keySignature: fetchedKey
        )
        onSelect(TileSong.fromAppleMusic(handle))
    }

    /// Calls the Apple Music REST catalog API via MusicDataRequest (which handles auth
    /// automatically) to read tempo (BPM) and keySignature — attributes that exist in
    /// the JSON but are not surfaced on MusicKit's Swift Song type.
    private func fetchExtendedAttributes(songID: String) async throws -> (tempo: Double?, key: String?) {
        // Resolve the user's storefront; fall back to "us" on any error.
        var countryCode = "us"
        if let sfURL = URL(string: "https://api.music.apple.com/v1/me/storefront"),
           let sfResp = try? await MusicDataRequest(urlRequest: URLRequest(url: sfURL)).response() {
            struct SFItem: Decodable { let id: String }
            struct SFResp: Decodable { let data: [SFItem] }
            if let decoded = try? JSONDecoder().decode(SFResp.self, from: sfResp.data),
               let first = decoded.data.first {
                countryCode = first.id
            }
        }

        guard let songURL = URL(string: "https://api.music.apple.com/v1/catalog/\(countryCode)/songs/\(songID)") else {
            return (nil, nil)
        }
        let songResp = try await MusicDataRequest(urlRequest: URLRequest(url: songURL)).response()

        struct SongAttrs: Decodable {
            let tempo: Double?
            let keySignature: String?
        }
        struct SongItem: Decodable { let attributes: SongAttrs }
        struct SongResp: Decodable { let data: [SongItem] }

        let attrs = try JSONDecoder().decode(SongResp.self, from: songResp.data).data.first?.attributes
        return (attrs?.tempo, attrs?.keySignature)
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
