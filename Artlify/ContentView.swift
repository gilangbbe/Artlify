//
//  ContentView.swift
//  Artlify / AppShell — `particles` branch
//
//  This branch replaces the diffusion stylization pipeline with a
//  classic interactive-installation surface: live camera passthrough,
//  Vision person-segmentation, and a GPU particle field whose force
//  vectors come from the spatial gradient of the segmentation mask.
//  Move in front of the camera → silhouette pushes particles around.
//
//  The diffusion files (DiffusionKit/, DiffusionBenchmark.swift,
//  LiveDiffusionDriver.swift) are intentionally left in the project but
//  are no longer referenced from the UI. Switch back to `main` for the
//  diffusion path.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var session = CameraSession()
    @State private var vision = VisionSession()
    @State private var field: ParticleField?
    @State private var showVisionOverlay = false
    @State private var showHUD = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraMetalView(renderer: session.renderer)
                .ignoresSafeArea()

            if showVisionOverlay {
                GeometryReader { proxy in
                    PoseOverlay(frame: vision.latestFrame, viewSize: proxy.size)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }

            if showHUD {
                statusHUD
                    .padding(12)

                VStack {
                    Spacer()
                    if let field {
                        particlePanel(field: field)
                            .padding(12)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color.black)
        .onAppear {
            session.start()
            vision.start(consuming: session)

            // Build the particle field on the renderer's device and hand
            // it to the renderer so the draw callback can advance + draw
            // particles every frame.
            if field == nil {
                do {
                    let f = try ParticleField(device: session.renderer.device)
                    session.renderer.particleField = f
                    self.field = f
                } catch {
                    print("ParticleField init failed: \(error)")
                }
            }
        }
        .onDisappear {
            vision.stop()
            session.stop()
        }
        // Push the latest segmentation mask into the renderer whenever
        // VisionSession publishes a new frame. The particle compute
        // shader reads it as a force-field source.
        .onChange(of: vision.passCount) { _, _ in
            session.renderer.submitMask(vision.latestFrame?.personMask)
        }
        // Keyboard: H toggles the HUD for clean recordings.
        .background(KeyHandler { key in
            if key.lowercased() == "h" { showHUD.toggle() }
        })
    }

    // MARK: - Top-left status

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
            visionStatusLine
            HStack(spacing: 6) {
                if !session.availableDevices.isEmpty {
                    Menu {
                        ForEach(session.availableDevices) { dev in
                            Button {
                                session.reconnect(deviceID: dev.id)
                            } label: {
                                Label(dev.localizedName,
                                      systemImage: dev.isContinuityCamera ? "iphone" : "camera")
                            }
                        }
                    } label: {
                        Label("Camera", systemImage: "camera.rotate")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { session.reconnect() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Toggle(isOn: $showVisionOverlay) {
                    Label("Vision", systemImage: "figure.stand")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                Button {
                    toggleFullscreen()
                } label: {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }

    private var statusText: String {
        switch session.status {
        case .idle:                 return "idle"
        case .starting:             return "starting…"
        case .running:              return "running"
        case .failed(let m):        return "failed: \(m)"
        }
    }

    @ViewBuilder
    private var visionStatusLine: some View {
        if let f = vision.latestFrame {
            let ms = Int(f.processingSeconds * 1000)
            let joints = f.joints.count
            Text("vision: \(joints) joints, \(ms) ms")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("vision: warming up…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bottom particle panel

    @ViewBuilder
    private func particlePanel(field: ParticleField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("particles", isOn: Binding(
                    get: { field.enabled },
                    set: { field.enabled = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Toggle("dark bg", isOn: Binding(
                    get: { session.renderer.darkBackground },
                    set: { session.renderer.darkBackground = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Text("\(field.count.formatted()) dots")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    field.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 16) {
                slider(label: "attraction",
                       value: Binding(get: { field.attraction },
                                      set: { field.attraction = $0 }),
                       range: 0...5,
                       fmt: "%.2f")
                slider(label: "flow",
                       value: Binding(get: { field.flow },
                                      set: { field.flow = $0 }),
                       range: 0...2,
                       fmt: "%.2f")
                slider(label: "swirl",
                       value: Binding(get: { field.flowScale },
                                      set: { field.flowScale = $0 }),
                       range: 1...20,
                       fmt: "%.1f")
                slider(label: "damping",
                       value: Binding(get: { field.damping },
                                      set: { field.damping = $0 }),
                       range: 0.5...0.999,
                       fmt: "%.3f")
            }

            HStack(spacing: 16) {
                slider(label: "size",
                       value: Binding(get: { field.pointSize },
                                      set: { field.pointSize = $0 }),
                       range: 1...14,
                       fmt: "%.1f")
                slider(label: "glow",
                       value: Binding(get: { field.glow },
                                      set: { field.glow = $0 }),
                       range: 0.1...3,
                       fmt: "%.2f")
                slider(label: "hue",
                       value: Binding(get: { field.hueShift },
                                      set: { field.hueShift = $0 }),
                       range: 0...1,
                       fmt: "%.2f")
                slider(label: "mask gate",
                       value: Binding(get: { field.maskGate },
                                      set: { field.maskGate = $0 }),
                       range: 0...1,
                       fmt: "%.2f")
            }

            HStack(spacing: 12) {
                Text("count")
                    .font(.caption)
                Picker("count", selection: Binding(
                    get: { field.count },
                    set: { field.count = $0 }
                )) {
                    ForEach([10_000, 30_000, 60_000, 120_000], id: \.self) { n in
                        Text(n.formatted()).tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Spacer()
                Text("press H to hide HUD")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func slider(label: String,
                        value: Binding<Float>,
                        range: ClosedRange<Float>,
                        fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): " + String(format: fmt, value.wrappedValue))
                .font(.caption.monospaced())
            Slider(value: value, in: range)
                .frame(width: 140)
        }
    }

    private func toggleFullscreen() {
        guard let window = NSApplication.shared.keyWindow
              ?? NSApplication.shared.windows.first
        else { return }
        window.toggleFullScreen(nil)
    }
}

// MARK: - Tiny key-event sink

private struct KeyHandler: NSViewRepresentable {
    let onKey: (String) -> Void

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onKey = onKey
        return v
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                onKey?(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

#Preview {
    ContentView()
}
