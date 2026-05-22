//
//  SongPickerView.swift
//  Artlify / GameKit — universe-tune branch
//
//  Full-screen overlay that lets the player choose a song before the
//  game starts.  Two built-in cards + an Apple Music card; clicking
//  a built-in fires onSelect, clicking the Apple Music card fires
//  onOpenAppleMusic so ContentView can push the browser overlay.
//

import Combine
import SwiftUI

// MARK: - Preview controller

@MainActor
final class SongPreviewController: ObservableObject {
    @Published private(set) var previewingTitle: String? = nil

    private var task: Task<Void, Never>? = nil
    private var player: NotePlayer? = nil

    func start(_ song: TileSong) {
        stop()
        previewingTitle = song.title
        let p = NotePlayer(song: song)
        player = p
        let events = song.events.filter { $0.beat < 32 }.sorted { $0.beat < $1.beat }
        let beatDur = song.beatDuration
        task = Task { [weak self] in
            var prevBeat = events.first?.beat ?? 0.0
            for event in events {
                if Task.isCancelled { break }
                let gap = (event.beat - prevBeat) * beatDur
                if gap > 0.005 {
                    do { try await Task.sleep(for: .seconds(gap)) }
                    catch { break }
                }
                if Task.isCancelled { break }
                p.play(lane: event.lane)
                prevBeat = event.beat
            }
            await MainActor.run { self?.previewingTitle = nil }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.teardown()
        player = nil
        previewingTitle = nil
    }
}

// MARK: - View

struct SongPickerView: View {
    let onSelect: (TileSong) -> Void
    let onCancel: () -> Void
    let onOpenAppleMusic: () -> Void

    @State private var hovered: String? = nil
    @StateObject private var preview = SongPreviewController()

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // Title
                VStack(spacing: 8) {
                    Text("METEOR SHOWER")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .yellow, .white],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .shadow(color: .orange.opacity(0.7), radius: 14)
                        .shadow(color: .yellow.opacity(0.4), radius: 30)
                    Text("when the universe is singing along.")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .italic()
                    Text("choose your song")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
                        .tracking(4)
                        .padding(.top, 4)
                }

                // Song cards
                HStack(spacing: 20) {
                    songCard(.experience)
                    songCard(.furElise)
                    appleMusicCard
                }

                // Cancel
                Button("cancel") { preview.stop(); onCancel() }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
                    .buttonStyle(.plain)
            }
            .padding(40)
        }
    }

    // MARK: - Built-in song card

    @ViewBuilder
    private func songCard(_ song: TileSong) -> some View {
        let isHovered    = hovered == song.title
        let isPreviewing = preview.previewingTitle == song.title
        let accent       = song.laneColors[song.laneColors.count / 2]

        Button { preview.stop(); onSelect(song) } label: {
            VStack(alignment: .leading, spacing: 14) {

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(song.composer)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Divider()
                    .overlay(accent.opacity(0.4))

                Text("\(Int(song.bpm)) bpm")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                HStack(spacing: 8) {
                    ForEach(0..<song.laneNotes.count, id: \.self) { lane in
                        VStack(spacing: 3) {
                            Circle()
                                .fill(song.laneColors[lane])
                                .frame(width: 7, height: 7)
                                .shadow(color: song.laneColors[lane].opacity(0.8), radius: 3)
                            Text(noteName(midi: song.laneNotes[lane]))
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                Spacer()

                // Preview / stop row
                Button {
                    if isPreviewing { preview.stop() } else { preview.start(song) }
                } label: {
                    Label(
                        isPreviewing ? "stop" : "preview",
                        systemImage: isPreviewing ? "stop.fill" : "waveform"
                    )
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(isPreviewing ? .orange : .white.opacity(0.40))
                }
                .buttonStyle(.plain)

                Text(isHovered ? "▶  play" : "click to play")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHovered ? accent : .white.opacity(0.45))
            }
            .padding(22)
            .frame(width: 210, height: 240)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isHovered ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent.opacity(isHovered ? 0.70 : 0.25), lineWidth: 1.5)
            )
            .shadow(color: accent.opacity(isHovered ? 0.30 : 0.05), radius: 20)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(duration: 0.18), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? song.title : nil }
    }

    // MARK: - Apple Music card

    @ViewBuilder
    private var appleMusicCard: some View {
        let isHovered = hovered == "__apple_music__"

        Button { onOpenAppleMusic() } label: {
            VStack(alignment: .leading, spacing: 14) {

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(colors: [.pink, .purple],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        Text("Apple Music")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    Text("any song in your library")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Divider()
                    .overlay(Color.pink.opacity(0.4))

                Text("120 bpm · catalog search")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                // Colour-wheel tile preview
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { i in
                        VStack(spacing: 3) {
                            Circle()
                                .fill(Color(hue: Double(i) / 8.0, saturation: 0.80, brightness: 1.0))
                                .frame(width: 7, height: 7)
                                .shadow(color: Color(hue: Double(i) / 8.0, saturation: 0.8,
                                                     brightness: 1.0).opacity(0.8), radius: 3)
                            Text("?")
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.40))
                        }
                    }
                }

                Spacer()

                Text(isHovered ? "▶  browse" : "click to browse")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.pink : .white.opacity(0.45))
            }
            .padding(22)
            .frame(width: 210, height: 240)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isHovered ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .pink.opacity(isHovered ? 0.70 : 0.25),
                                .purple.opacity(isHovered ? 0.70 : 0.25)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .pink.opacity(isHovered ? 0.30 : 0.05), radius: 20)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(duration: 0.18), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? "__apple_music__" : nil }
    }

    // MARK: - Helpers

    private func noteName(midi: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(midi) / 12 - 1
        let name   = names[Int(midi) % 12]
        return "\(name)\(octave)"
    }
}
