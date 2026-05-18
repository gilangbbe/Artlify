//
//  MusicSearchSheet.swift
//  Artlify / AppShell — `particles` branch
//
//  Karaoke phase 2 — UI slice.
//
//  A music-search surface (text field + result rows + load action)
//  that lives behind a `.sheet` on the main HUD. **Pure UI** for now:
//  results come from a hardcoded mock catalog so we can iterate on the
//  search/select experience without touching MusicKit, network, or
//  permissions. Each mock track is backed by the existing sample LRC
//  so picking any of them gives a runnable karaoke playthrough today.
//
//  Stage 2-network slice will swap `MockMusicCatalog.search(_:)` for a
//  real `MusicCatalogSearchRequest(term:types:[Song.self])` call and
//  the per-row `lrc` payload for an `LRCLibClient.fetch(...)` GET.
//  The sheet's view code, the result-row layout, and the
//  `onSelect`-back-into-`KaraokeStore` plumbing stay identical.
//

import SwiftUI
import MusicKit

// MARK: - Model

/// What kind of source a result came from. Carries any source-
/// specific payload (e.g. the MusicKit `Song` we need to actually
/// queue + play). Read by `ContentView.onSelect` to dispatch.
enum MusicResultKind: Hashable {
    case demo
    case lrclib
    case appleMusic(Song)
}

/// A single search result. Marked `Identifiable` for `List` row IDs.
/// Field shape matches what MusicKit's `Song` exposes (title, artist
/// name, duration) so the network swap is a 1-for-1 mapping.
struct MusicSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let durationSeconds: Double
    /// SF Symbol used as artwork stand-in until we have real cover art
    /// from MusicKit. The "DEMO" badge in the row already signals
    /// these are placeholders.
    let artworkSystemImage: String
    /// LRC source. May be empty for Apple Music rows — lyrics are
    /// fetched from LRCLIB by title+artist after selection in that
    /// case (MusicKit lyrics need an extra capability we don't have).
    let lrc: String
    /// Where this row came from + any payload needed to act on it.
    let kind: MusicResultKind
}

// MARK: - Mock catalog

/// Hardcoded catalog. Five tracks, all currently backed by the same
/// sample LRC — that's fine for the UI slice because we're testing
/// the *flow* (search → pick → karaoke starts), not the lyric variety.
enum MockMusicCatalog {
    static let all: [MusicSearchResult] = [
        MusicSearchResult(
            id: "demo-loop",
            title: "Artlify Demo Loop",
            artist: "Placeholder",
            durationSeconds: 34,
            artworkSystemImage: "waveform.circle.fill",
            lrc: LRCParser.sample,
            kind: .demo
        ),
        MusicSearchResult(
            id: "still-frame",
            title: "Still Frame",
            artist: "Negative Camera",
            durationSeconds: 34,
            artworkSystemImage: "camera.aperture",
            lrc: LRCParser.sample,
            kind: .demo
        ),
        MusicSearchResult(
            id: "silhouette",
            title: "Silhouette",
            artist: "Curl Noise Ensemble",
            durationSeconds: 34,
            artworkSystemImage: "person.fill.viewfinder",
            lrc: LRCParser.sample,
            kind: .demo
        ),
        MusicSearchResult(
            id: "shockwave",
            title: "Shockwave",
            artist: "Body Center",
            durationSeconds: 34,
            artworkSystemImage: "wave.3.right.circle.fill",
            lrc: LRCParser.sample,
            kind: .demo
        ),
        MusicSearchResult(
            id: "ascii-rain",
            title: "ASCII Rain",
            artist: "Glyph Atlas",
            durationSeconds: 34,
            artworkSystemImage: "textformat.abc.dottedunderline",
            lrc: LRCParser.sample,
            kind: .demo
        )
    ]

    /// Trivial substring filter. The real MusicKit call will rank
    /// server-side; for now we just lower-case-contains across title +
    /// artist so the UI behaves like a real incremental search.
    static func search(_ term: String) -> [MusicSearchResult] {
        let q = term.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(q)
            || $0.artist.lowercased().contains(q)
        }
    }
}

// MARK: - Sheet view

/// Where the sheet pulls candidates from. Mock is the local
/// hardcoded catalog (instant, offline, all backed by the sample
/// LRC). LRCLIB hits the live HTTP API for real time-synced lyrics.
enum MusicSearchSource: String, CaseIterable, Identifiable {
    case demo = "Demo"
    case lrclib = "LRCLIB"
    case appleMusic = "Apple Music"
    var id: String { rawValue }
}

/// Music search sheet. Opens from the karaoke HUD row. Picking a
/// result calls `onSelect`, which the caller wires up to load the
/// track into `KaraokeStore` and start playback.
struct MusicSearchSheet: View {
    /// Called with the chosen result when the user picks a row. The
    /// caller is responsible for parsing `result.lrc` into the store
    /// and starting playback — we don't touch `KaraokeStore` from
    /// here, to keep this view free of model dependencies.
    var onSelect: (MusicSearchResult) -> Void
    /// Dismiss closure — typically `{ dismiss() }` provided by the
    /// caller (or the sheet's own `@Environment(\.dismiss)`).
    var onClose: () -> Void

    @State private var query: String = ""
    @State private var source: MusicSearchSource = .appleMusic
    /// Live results. Demo source fills this synchronously on every
    /// query change; LRCLIB source fills it from an async fetch.
    @State private var results: [MusicSearchResult] = MockMusicCatalog.all
    @State private var isFetching: Bool = false
    @State private var errorText: String? = nil
    /// In-flight LRCLIB task — cancelled when the query changes so
    /// we don't race stale responses onto a newer query's results.
    @State private var fetchTask: Task<Void, Never>? = nil
    /// Picking a row sets this so we can highlight the chosen result
    /// for a beat before the sheet dismisses; reads cleanly in demo.
    @State private var pickedID: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ---- Header bar: title + close.
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.secondary)
                Text("Search music")
                    .font(.headline)
                Spacer()
                // Source badge — colour-coded so the user always knows
                // whether they're looking at fake demo data or live
                // LRCLIB results. Orange = mock, green = live network.
                sourceBadge
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ---- Source picker (Demo vs LRCLIB).
            Picker("Source", selection: $source) {
                ForEach(MusicSearchSource.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .onChange(of: source) { _, _ in refresh() }

            // ---- Search field.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField({
                    switch source {
                    case .demo:       return "title or artist…"
                    case .lrclib:     return "e.g. \"weezer say it ain't so\"…"
                    case .appleMusic: return "any song on Apple Music…"
                    }
                }(),
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .onSubmit { refresh() }
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                        refresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )
            .padding(.horizontal, 16)
            // Debounce query changes so we don't fire a request on
            // every keystroke. 350 ms is the sweet spot for music
            // search — long enough to skip mid-word typing, short
            // enough that the user feels the field is responsive.
            .onChange(of: query) { _, _ in
                fetchTask?.cancel()
                fetchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !Task.isCancelled { await runSearch() }
                }
            }

            Divider()
                .padding(.top, 10)

            // ---- Results list / states.
            if let errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                    Button("Retry") { refresh() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !isFetching {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text({
                        switch source {
                        case .demo:       return "No matches in the demo catalog."
                        case .lrclib:     return "No matches on LRCLIB."
                        case .appleMusic: return "Type a song to search Apple Music."
                        }
                    }())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text({
                        switch source {
                        case .demo:       return "Try \"silhouette\" or \"shockwave\"."
                        case .lrclib:     return "Try a real song title and artist."
                        case .appleMusic: return "e.g. \"daft punk one more time\"…"
                        }
                    }())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { r in
                            resultRow(r)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }

            // ---- Footer hint.
            Divider()
            HStack(spacing: 6) {
                Image(systemName: {
                    switch source {
                    case .demo:       return "info.circle"
                    case .lrclib:     return "network"
                    case .appleMusic: return "applelogo"
                    }
                }())
                Text({
                    switch source {
                    case .demo:       return "Demo catalog — all entries use the sample LRC."
                    case .lrclib:     return "Live results from lrclib.net (no auth, public DB)."
                    case .appleMusic: return "Live Apple Music catalog. Lyrics fetched from LRCLIB after pick."
                    }
                }())
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 460, idealWidth: 520,
               minHeight: 420, idealHeight: 520)
        .background(.regularMaterial)
        .onAppear { refresh() }
        .onDisappear { fetchTask?.cancel() }
    }

    // MARK: Source badge

    private var sourceBadge: some View {
        let text: String
        let tint: Color
        switch source {
        case .demo:       text = "DEMO CATALOG";  tint = .orange
        case .lrclib:     text = "LIVE — LRCLIB";  tint = .green
        case .appleMusic: text = "APPLE MUSIC";    tint = .pink
        }
        return Text(text)
            .font(.caption2.monospaced().bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(0.25))
            )
            .foregroundStyle(tint)
    }

    // MARK: Refresh / fetch

    /// Re-run whatever source is selected without waiting on debounce.
    /// Called on source-change, on submit, on clear, and on appear.
    private func refresh() {
        fetchTask?.cancel()
        fetchTask = Task { await runSearch() }
    }

    /// Core search dispatcher. Branches on `source` and writes the
    /// results array + error state on the main actor.
    @MainActor
    private func runSearch() async {
        errorText = nil
        switch source {
        case .demo:
            // Synchronous: filter the hardcoded catalog.
            isFetching = false
            results = MockMusicCatalog.search(query)
        case .lrclib:
            let q = query.trimmingCharacters(in: .whitespaces)
            // Empty query on LRCLIB: show nothing rather than firing
            // a useless network call.
            guard !q.isEmpty else {
                results = []
                isFetching = false
                return
            }
            isFetching = true
            defer { isFetching = false }
            do {
                let hits = try await LRCLibClient.search(query: q)
                if Task.isCancelled { return }
                let mapped = hits.compactMap { mapLRCLib($0) }
                if mapped.isEmpty {
                    results = []
                    // Distinguish "server said zero hits" from "hits
                    // came back but none had synced lyrics" — both
                    // are no-results from the user's POV, so reuse
                    // the empty-state UI rather than an error.
                    return
                }
                results = mapped
            } catch is CancellationError {
                return
            } catch let e as LRCLibError {
                results = []
                errorText = e.errorDescription
            } catch {
                results = []
                errorText = error.localizedDescription
            }
        case .appleMusic:
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else {
                results = []
                isFetching = false
                return
            }
            isFetching = true
            defer { isFetching = false }
            do {
                let songs = try await MusicKitClient.searchSongs(query: q)
                if Task.isCancelled { return }
                results = songs.map { mapAppleMusic($0) }
            } catch is CancellationError {
                return
            } catch let e as MusicKitError {
                results = []
                errorText = e.errorDescription
            } catch {
                results = []
                errorText = error.localizedDescription
            }
        }
    }

    /// Map an LRCLIB hit to our unified result type. Drops entries
    /// without synced lyrics — the karaoke overlay needs time stamps,
    /// plain text is useless to it.
    private func mapLRCLib(_ t: LRCLibTrack) -> MusicSearchResult? {
        guard let synced = t.syncedLyrics, !synced.isEmpty else { return nil }
        return MusicSearchResult(
            id: "lrclib-\(t.id)",
            title: t.trackName,
            artist: t.artistName,
            durationSeconds: t.duration ?? 0,
            artworkSystemImage: "music.quarternote.3",
            lrc: synced,
            kind: .lrclib
        )
    }

    /// Map an Apple Music `Song` to our unified result type. `lrc` is
    /// empty here — lyrics are fetched after the user picks the row
    /// (saves us doing N LRCLIB round-trips per keystroke).
    private func mapAppleMusic(_ s: Song) -> MusicSearchResult {
        MusicSearchResult(
            id: "applemusic-\(s.id.rawValue)",
            title: s.title,
            artist: s.artistName,
            durationSeconds: s.duration ?? 0,
            artworkSystemImage: "applelogo",
            lrc: "",
            kind: .appleMusic(s)
        )
    }

    @ViewBuilder
    private func resultRow(_ r: MusicSearchResult) -> some View {
        let isPicked = (pickedID == r.id)
        Button {
            pickedID = r.id
            // Brief highlight, then commit + close. 120 ms is enough
            // for the colour change to register without making the
            // selection feel laggy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                onSelect(r)
                onClose()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: r.artworkSystemImage)
                    .font(.system(size: 24))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                    Text(r.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(timecode(r.durationSeconds))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Image(systemName: isPicked
                      ? "checkmark.circle.fill"
                      : "play.circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPicked
                          ? Color.accentColor.opacity(0.18)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timecode(_ secs: Double) -> String {
        let mm = Int(secs) / 60
        let ss = Int(secs) % 60
        return String(format: "%d:%02d", mm, ss)
    }
}
