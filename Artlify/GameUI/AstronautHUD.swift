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
        // Fill the full window so centering is relative to the screen,
        // not the parent ZStack's .topLeading alignment.
        ZStack {
            // ── Idle start prompt — screen centre ─────────────────────
            if game.gameState == .idle {
                startPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            // ── 3-2-1 countdown — screen centre ───────────────────────
            if case .countdown(let n) = game.gameState {
                countdownDisplay(n: n)
                    .transition(.opacity)
            }

            // ── Game over — screen centre ─────────────────────────────
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: game.gameState)
    }

    // MARK: - In-game readout

    private var inGameReadout: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Star-dust count
            VStack(alignment: .trailing, spacing: 3) {
                Text("Star Dust Collected")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.70))
                HStack(spacing: 6) {
                    ForEach(0..<min(5, max(0, game.starDust)), id: \.self) { _ in
                        Image(systemName: "sparkle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    if game.starDust > 5 {
                        Text("+\(game.starDust - 5)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }
            }
            // Distance — large and bold so it's readable mid-game
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(game.score) m")
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Text("dist")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
                    .kerning(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Countdown

    private func countdownDisplay(n: Int) -> some View {
        VStack(spacing: 10) {
            Text("\(n)")
                .font(.system(size: 96, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.95), radius: 14)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.50), radius: 32)
                .id(n)
                .transition(.scale(scale: 1.35).combined(with: .opacity))
            Text("GET READY")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                .kerning(6)
        }
        .fixedSize()
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.04, green: 0.07, blue: 0.18).opacity(0.88))
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.30), radius: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color(red: 0.30, green: 0.58, blue: 1.0).opacity(0.40),
                            lineWidth: 1
                        )
                )
        )
        .animation(.spring(duration: 0.22), value: n)
    }

    // MARK: - Start prompt

    private var startPrompt: some View {
        VStack(alignment: .center, spacing: 16) {

            // Title
            Text("METEOR RUN")
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .kerning(3)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.9), radius: 10)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.5), radius: 22)

            Divider()
                .background(Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.45))

            // Game rules
            VStack(alignment: .leading, spacing: 10) {
                Text("GAME RULES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                    .kerning(3)

                VStack(alignment: .leading, spacing: 6) {
                    ruleRow(key: "JUMP",    desc: "leap over ground rocks")
                    ruleRow(key: "DUCK",    desc: "dodge incoming meteors")
                    ruleRow(key: "✦",       desc: "collect star dust for extra lives")
                    ruleRow(key: "METEOR",  desc: "loses one star dust")
                    ruleRow(key: "0 left",  desc: "mission failed")
                }
            }

            Divider()
                .background(Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.45))

            Button {
                game.startCountdown()
            } label: {
                Label("start", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.20, green: 0.45, blue: 0.95))
            .controlSize(.regular)
        }
        .fixedSize()
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.04, green: 0.07, blue: 0.18).opacity(0.92))
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.35), radius: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color(red: 0.30, green: 0.58, blue: 1.0).opacity(0.45),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Game over

    private var gameOverPanel: some View {
        VStack(alignment: .center, spacing: 14) {

            // Title
            Text("MISSION FAILED")
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .kerning(3)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.9), radius: 10)
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.5), radius: 22)

            Divider()
                .background(Color(red: 0.35, green: 0.65, blue: 1.0).opacity(0.45))

            // Stats
            VStack(spacing: 6) {
                HStack {
                    Text("dist")
                        .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                    Spacer()
                    Text("\(game.score) m")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 15, weight: .bold, design: .monospaced))

                if game.highScore > 0 {
                    HStack {
                        Text("best")
                            .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                        Spacer()
                        Text("\(game.highScore) m")
                            .foregroundStyle(Color(red: 0.75, green: 0.88, blue: 1.0))
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
            }

            // Button
            Button {
                game.startCountdown()
            } label: {
                Label("try again", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.20, green: 0.45, blue: 0.95))
            .controlSize(.regular)
        }
        .fixedSize()
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.04, green: 0.07, blue: 0.18).opacity(0.92))
                .shadow(color: Color(red: 0.25, green: 0.55, blue: 1.0).opacity(0.35), radius: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color(red: 0.30, green: 0.58, blue: 1.0).opacity(0.45),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func ruleRow(key: String, desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                .frame(minWidth: 52, alignment: .leading)
            Text(desc)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.80))
        }
    }
}
