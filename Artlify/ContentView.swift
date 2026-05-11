//
//  ContentView.swift
//  Artlify / AppShell
//
//  M0 surface: live camera passthrough via Metal, plus a tiny HUD that
//  shows status and first-frame latency. Everything else (Vision overlay,
//  diffusion, prompt UI) is added in later milestones.
//

import SwiftUI

struct ContentView: View {
    @State private var session = CameraSession()

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraMetalView(renderer: session.renderer)
                .ignoresSafeArea()

            statusHUD
                .padding(12)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(Color.black)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var statusHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.system(.caption, design: .monospaced))
            if let ms = session.firstFrameLatencyMS {
                Text(String(format: "first frame: %.0f ms", ms))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var statusText: String {
        switch session.status {
        case .idle:     return "idle"
        case .starting: return "starting…"
        case .running:  return "live"
        case .failed(let msg): return "error: \(msg)"
        }
    }
}

#Preview {
    ContentView()
}
