//
//  AstronautHUD.swift
//  Artlify / GameUI
//
//  Game UI overlay using the same visual language as the existing statusHUD:
//  dark semi-transparent pill, white monospaced caption text, no heavy chrome.
//  Sits above all other layers in ContentView's ZStack.
//

import SwiftUI

struct AstronautHUD: View {
    let game: GameEngine

    var body: some View {
        ZStack {
            // ── Idle start prompt ─────────────────────────────────────
            if game.gameState == .idle {
                startPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            // ── 3-2-1 countdown ───────────────────────────────────────
            if case .countdown(let n) = game.gameState {
                countdownDisplay(n: n)
                    .transition(.opacity)
            }

            // ── Game over ─────────────────────────────────────────────
            if game.gameState == .gameOver {
                gameOverPanel
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // ── In-game top-right readout ─────────────────────────────
            if game.gameState == .playing || game.gameState == .gameOver {
                inGameReadout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: game.gameState)
    }

    // MARK: - In-game readout

    private var inGameReadout: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Star-dust count as sparkle icons (≤ 5) or icon + number
            HStack(spacing: 4) {
                ForEach(0..<min(5, max(0, game.starDust)), id: \.self) { _ in
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
                if game.starDust > 5 {
                    Text("+\(game.starDust - 5)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            Text("dist  \(game.score) m")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Countdown

    private func countdownDisplay(n: Int) -> some View {
        VStack(spacing: 6) {
            Text("\(n)")
                .font(.system(size: 96, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .id(n)
                .transition(.scale(scale: 1.35).combined(with: .opacity))
            Text("get ready")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(5)
        }
        .animation(.spring(duration: 0.22), value: n)
    }

    // MARK: - Start prompt  (matches existing statusHUD pill style)

    private var startPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("astronaut run")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
            Text("jump  →  clear ground rocks")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Text("duck  →  dodge incoming meteors")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Button {
                game.startCountdown()
            } label: {
                Label("start", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    // MARK: - Game over  (same pill style, slightly wider)

    private var gameOverPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mission failed")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
            Text("dist  \(game.score) m")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.70))
            if game.highScore > 0 {
                Text("best  \(game.highScore) m")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Button {
                game.startCountdown()
            } label: {
                Label("try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}
