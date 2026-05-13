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
import Combine

struct ContentView: View {
    @State private var session = CameraSession()
    @State private var vision = VisionSession()
    @State private var field: ParticleField?
    @State private var audio = AudioReactor()
    @State private var showVisionOverlay = false
    @State private var showHUD = true
    /// Drives the random negative-camera flashes around body parts.
    /// Tick rate is intentionally slow (~9 Hz) so flashes feel
    /// stuttery and intentional rather than continuous noise.
    @State private var boxTimer = Timer.publish(every: 0.11, on: .main, in: .common).autoconnect()
    /// Last time we fired an ASCII shockwave (rate-limit transients).
    @State private var lastAsciiShock: CFAbsoluteTime = 0

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
                    f.audioReactor = audio
                    session.renderer.particleField = f
                    self.field = f
                } catch {
                    print("ParticleField init failed: \(error)")
                }
            }
        }
        .onDisappear {
            audio.stop()
            vision.stop()
            session.stop()
        }
        // Push the latest segmentation mask into the renderer whenever
        // VisionSession publishes a new frame. The particle compute
        // shader reads it as a force-field source.
        .onChange(of: vision.passCount) { _, _ in
            session.renderer.submitMask(vision.latestFrame?.personMask)
            // Update body anchor so audio shockwaves radiate from
            // inside the actual body, not screen center.
            if let f = vision.latestFrame, let field {
                let bc = bodyCenter(from: f.joints)
                field.bodyCenter = bc
                session.renderer.asciiOrigin = bc
            }
        }
        // Periodically flash 1–3 negative-camera boxes around random
        // body joints. Empty frames (no joints) are silently skipped.
        .onReceive(boxTimer) { _ in
            tickNegativeBoxes()
            tickAsciiShockwave()
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
                Text("trails")
                    .font(.caption)
                Slider(value: Binding(
                    get: { session.renderer.trailDecay },
                    set: { session.renderer.trailDecay = $0 }
                ), in: 0.80...0.995)
                    .frame(width: 140)
                Text(String(format: "%.3f", session.renderer.trailDecay))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Toggle("trails on", isOn: Binding(
                    get: { session.renderer.trailsEnabled },
                    set: { session.renderer.trailsEnabled = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("neg boxes", isOn: Binding(
                    get: { session.renderer.negativeBoxesEnabled },
                    set: { session.renderer.negativeBoxesEnabled = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Text("intensity")
                    .font(.caption)
                Slider(value: Binding(
                    get: { session.renderer.negativeBoxesPeak },
                    set: { session.renderer.negativeBoxesPeak = $0 }
                ), in: 0.1...1.0)
                    .frame(width: 140)
                Text(String(format: "%.2f", session.renderer.negativeBoxesPeak))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("ascii", isOn: Binding(
                    get: { session.renderer.asciiEnabled },
                    set: { session.renderer.asciiEnabled = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Text("cell")
                    .font(.caption)
                Slider(value: Binding(
                    get: { session.renderer.asciiCellSize },
                    set: { session.renderer.asciiCellSize = $0 }
                ), in: 4...28)
                    .frame(width: 140)
                Text(String(format: "%.0f", session.renderer.asciiCellSize) + " px")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    session.renderer.triggerAsciiShockwave(
                        origin: session.renderer.asciiOrigin
                    )
                } label: {
                    Label("pulse", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }

            audioRow(field: field)

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
    private func audioRow(field: ParticleField) -> some View {
        let f = audio.latest
        HStack(spacing: 12) {
            Toggle(audio.isRunning ? "audio on" : "audio off", isOn: Binding(
                get: { audio.isRunning },
                set: { newVal in
                    if newVal {
                        audio.start()
                        if field.audioStrength == 0 { field.audioStrength = 1.0 }
                    } else {
                        audio.stop()
                    }
                }
            ))
            .toggleStyle(.button)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("strength: " + String(format: "%.2f", field.audioStrength))
                    .font(.caption.monospaced())
                Slider(value: Binding(
                    get: { field.audioStrength },
                    set: { field.audioStrength = $0 }
                ), in: 0...2)
                    .frame(width: 140)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("gain: " + String(format: "%.2f", audio.gain))
                    .font(.caption.monospaced())
                Slider(value: Binding(
                    get: { audio.gain },
                    set: { audio.gain = $0 }
                ), in: 0.1...4)
                    .frame(width: 100)
            }

            // Tiny live meter — 4 bars: low / mid / high / level.
            HStack(spacing: 4) {
                meterBar("L", value: f.low,   color: .cyan)
                meterBar("M", value: f.mid,   color: .green)
                meterBar("H", value: f.high,  color: .pink)
                meterBar("\u{2261}", value: f.level, color: .yellow)
            }
            .frame(height: 28)

            if let err = audio.lastError {
                Text(err)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.red)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func meterBar(_ label: String, value: Float, color: Color) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(color.opacity(0.25))
                .frame(width: 10, height: 22)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(color)
                        .frame(width: 10, height: CGFloat(max(0, min(1, value))) * 22)
                }
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Body anchor + negative-camera box flashes

    /// Average of detected hip joints (Vision uv, top-left flipped),
    /// falling back to the centroid of all confident joints, falling
    /// back to screen center. Drives the audio-shockwave origin.
    private func bodyCenter(from joints: [VisionJoint]) -> SIMD2<Float> {
        let hips = joints.filter { $0.id.localizedCaseInsensitiveContains("hip") }
        let pool = hips.isEmpty ? joints : hips
        guard !pool.isEmpty else { return SIMD2<Float>(0.5, 0.5) }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for j in pool { sx += j.point.x; sy += j.point.y }
        let n = CGFloat(pool.count)
        // Vision y is bottom-left origin; uv is top-left → flip.
        return SIMD2<Float>(Float(sx / n), Float(1.0 - sy / n))
    }

    /// One tick of the negative-camera flash driver. Picks a random
    /// subset (1–3) of confident joints and tells the renderer to flash
    /// a box at each, with a random aspect-ratio sized roughly to the
    /// expected limb extent. Off-frame joints are skipped.
    private func tickNegativeBoxes() {
        guard session.renderer.negativeBoxesEnabled,
              let f = vision.latestFrame
        else { return }
        let candidates = f.joints.filter { $0.confidence >= 0.4 }
        guard !candidates.isEmpty else { return }
        let pickN = Int.random(in: 1...min(3, candidates.count))
        var picked: Set<Int> = []
        while picked.count < pickN {
            picked.insert(Int.random(in: 0..<candidates.count))
        }
        for idx in picked {
            let j = candidates[idx]
            // Vision y → uv y flip.
            let cx = Float(j.point.x)
            let cy = Float(1.0 - j.point.y)
            // Random rectangle: 5–14% wide, 5–14% tall, decoupled so
            // boxes vary from squares to long strips.
            let hw = Float.random(in: 0.025...0.07)
            let hh = Float.random(in: 0.025...0.07)
            let dur = Double.random(in: 0.18...0.55)
            session.renderer.flashNegativeBox(
                center: SIMD2<Float>(cx, cy),
                halfSize: SIMD2<Float>(hw, hh),
                duration: dur
            )
        }
    }

    /// Watch the audio reactor's transient value and trigger an ASCII
    /// shockwave when it crosses a threshold (rate-limited so a single
    /// loud event doesn't fire dozens of overlapping rings).
    private func tickAsciiShockwave() {
        guard session.renderer.asciiEnabled, audio.isRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // 0.18s minimum gap between rings.
        guard now - lastAsciiShock > 0.18 else { return }
        if audio.latest.transient > 0.18 {
            session.renderer.triggerAsciiShockwave(
                origin: session.renderer.asciiOrigin
            )
            lastAsciiShock = now
        }
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
