//
//  SongPickerView.swift
//  Artlify / GameKit — universe-tune branch
//
//  Full-screen overlay that lets the player choose a song before the
//  game starts.  Two built-in cards + an Apple Music card; clicking
//  a built-in fires onSelect, clicking the Apple Music card fires
//  onOpenAppleMusic so ContentView can push the browser overlay.
//

import SwiftUI

struct SongPickerView: View {
    let onSelect: (TileSong) -> Void
    let onCancel: () -> Void
    let onOpenAppleMusic: () -> Void

    @State private var hovered: String? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // Title
                VStack(spacing: 6) {
                    Text("universe tune")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40))
                        .tracking(6)
                    Text("choose your song")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                // Song cards
                HStack(spacing: 20) {
                    songCard(.experience)
                    songCard(.furElise)
                    appleMusicCard
                }

                // Cancel
                Button("cancel") { onCancel() }
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
        let isHovered = hovered == song.title
        let accent    = song.laneColors[2]

        Button { onSelect(song) } label: {
            VStack(alignment: .leading, spacing: 16) {

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
                    ForEach(0..<4, id: \.self) { lane in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(song.laneColors[lane])
                                .frame(width: 10, height: 10)
                                .shadow(color: song.laneColors[lane].opacity(0.8), radius: 4)
                            Text(noteName(midi: song.laneNotes[lane]))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                Spacer()

                Text(isHovered ? "▶  play" : "click to play")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHovered ? accent : .white.opacity(0.45))
            }
            .padding(22)
            .frame(width: 210, height: 220)
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
            VStack(alignment: .leading, spacing: 16) {

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
                    ForEach(0..<4, id: \.self) { i in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(Color(hue: Double(i) / 4.0, saturation: 0.80, brightness: 1.0))
                                .frame(width: 10, height: 10)
                                .shadow(color: Color(hue: Double(i)/4.0, saturation: 0.8,
                                                     brightness: 1.0).opacity(0.8), radius: 4)
                            Text("?")
                                .font(.system(size: 9, design: .monospaced))
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
            .frame(width: 210, height: 220)
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
