//
//  SongPickerView.swift
//  Artlify / GameKit — universe-tune branch
//
//  Full-screen overlay that lets the player choose a song before the
//  game starts.  Two cards side-by-side; clicking one fires the
//  onSelect callback and dismisses the picker.
//

import SwiftUI

struct SongPickerView: View {
    let onSelect: (TileSong) -> Void
    let onCancel: () -> Void

    @State private var hovered: String? = nil

    var body: some View {
        ZStack {
            // Dark backdrop
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
                HStack(spacing: 24) {
                    songCard(.experience)
                    songCard(.furElise)
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

    // MARK: - Card

    @ViewBuilder
    private func songCard(_ song: TileSong) -> some View {
        let isHovered = hovered == song.title
        let accent    = song.laneColors[2]   // mid-lane colour as card accent

        Button { onSelect(song) } label: {
            VStack(alignment: .leading, spacing: 16) {

                // Song title + composer
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(song.composer)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                }

                Divider()
                    .overlay(accent.opacity(0.4))

                // BPM + note lane preview
                HStack(spacing: 6) {
                    Text("\(Int(song.bpm)) bpm")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }

                // Lane colour swatches + note names
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

                // CTA
                Text(isHovered ? "▶  play" : "click to play")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isHovered ? accent : .white.opacity(0.45))
            }
            .padding(24)
            .frame(width: 220, height: 220)
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

    // MARK: - Helpers

    /// Human-readable note name from a MIDI number.
    private func noteName(midi: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = Int(midi) / 12 - 1
        let name   = names[Int(midi) % 12]
        return "\(name)\(octave)"
    }
}
