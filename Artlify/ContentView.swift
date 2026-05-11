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
    @State private var benchmark = DiffusionBenchmark()

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraMetalView(renderer: session.renderer)
                .ignoresSafeArea()

            statusHUD
                .padding(12)

            VStack {
                Spacer()
                benchmarkPanel
                    .padding(12)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color.black)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var statusHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .font(.system(.caption, design: .monospaced))
            if let device = session.activeDeviceName {
                Text("device: \(device)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let ms = session.firstFrameLatencyMS {
                Text(String(format: "first frame: %.0f ms", ms))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if !session.availableDevices.isEmpty {
                    Menu {
                        ForEach(session.availableDevices) { dev in
                            Button {
                                session.reconnect(deviceID: dev.id)
                            } label: {
                                Label(
                                    dev.localizedName,
                                    systemImage: dev.isContinuityCamera ? "iphone" : "camera"
                                )
                            }
                        }
                    } label: {
                        Label("Camera", systemImage: "camera.rotate")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button {
                    session.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption2)
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

    // MARK: - M1 benchmark panel

    @ViewBuilder
    private var benchmarkPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let img = benchmark.resultImage {
                    Image(decorative: img, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.4))
                        .frame(width: 220, height: 220)
                        .overlay(
                            Text("no result yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextField("prompt", text: $benchmark.prompt)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 320)

                    HStack(spacing: 12) {
                        Stepper(value: $benchmark.stepCount, in: 1...8) {
                            Text("steps: \(benchmark.stepCount)")
                                .font(.caption)
                        }
                        .fixedSize()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "strength: %.2f", benchmark.strength))
                                .font(.caption)
                            Slider(value: $benchmark.strength, in: 0.1...0.95)
                                .frame(width: 160)
                        }
                    }

                    HStack(spacing: 8) {
                        loadButton
                        Button {
                            benchmark.run(using: session)
                        } label: {
                            Label("Stylize current frame", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(benchmark.loadState != .loaded ||
                                  benchmark.runState == .running ||
                                  session.latestPixelBuffer == nil)
                    }

                    benchmarkStatusText
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var loadButton: some View {
        switch benchmark.loadState {
        case .idle, .failed:
            if benchmark.modelDirectoryExists {
                Button {
                    benchmark.load()
                } label: {
                    Label("Load model", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    benchmark.revealModelFolder()
                } label: {
                    Label("Reveal model folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .help("No model found. Click to open the folder where the converted SD Turbo .mlmodelc bundle should live.")
            }
        case .loading:
            ProgressView().controlSize(.small)
            Text("loading model…").font(.caption)
        case .loaded:
            Label("model loaded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var benchmarkStatusText: some View {
        let text: String = {
            switch benchmark.runState {
            case .idle: return ""
            case .running: return "running…"
            case .done(let s, let n):
                let fps = s > 0 ? 1.0 / s : 0.0
                return String(
                    format: "img2img: %.0f ms (%.1f FPS) · %d steps",
                    s * 1000, fps, n
                )
            case .failed(let msg): return "error: \(msg)"
            }
        }()
        if !text.isEmpty {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        if !benchmark.modelDirectoryExists, benchmark.loadState == .idle {
            Text("Model not found at:\n\(benchmark.modelDirectory.path)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }
}

#Preview {
    ContentView()
}
