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
    @State private var vision = VisionSession()
    @State private var live: LiveDiffusionDriver?
    @State private var showVisionOverlay = false
    @State private var liveOn: Bool = false
    @State private var styleStrength: Float = 1.0
    @State private var maskMode: MaskMode = .background

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
        .onAppear {
            session.start()
            vision.start(consuming: session)
            if live == nil {
                live = LiveDiffusionDriver(renderer: session.renderer)
            }
        }
        .onDisappear {
            live?.stop()
            vision.stop()
            session.stop()
        }
        // Push the latest segmentation mask into the renderer whenever
        // VisionSession publishes a new frame. Cheap; the renderer just
        // re-binds a CVMetalTexture pointer.
        .onChange(of: vision.passCount) { _, _ in
            session.renderer.submitMask(vision.latestFrame?.personMask)
            // Make the latest pose/motion data visible to PromptComposer
            // for the next diffusion pass.
            benchmark.latestVisionFrame = vision.latestFrame
        }
        .onChange(of: styleStrength) { _, new in
            session.renderer.styleStrength = new
        }
        .onChange(of: maskMode) { _, new in
            session.renderer.maskMode = new
        }
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
            visionStatusLine
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

    @ViewBuilder
    private var visionStatusLine: some View {
        let ms = vision.smoothedProcessingSeconds * 1000.0
        let fps = vision.smoothedProcessingSeconds > 0 ? 1.0 / vision.smoothedProcessingSeconds : 0
        let jointCount = vision.latestFrame?.joints.count ?? 0
        let hasMask = vision.latestFrame?.personMask != nil
        if vision.passCount > 0 {
            Text(String(format: "vision: %.0f ms (%.1f Hz) · %d joints · mask: %@",
                        ms, fps, jointCount, hasMask ? "yes" : "no"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
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
                    presetPicker
                    TextField("extra prompt (optional)", text: $benchmark.prompt)
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
                        Toggle(isOn: Binding(
                            get: { liveOn },
                            set: { newValue in
                                liveOn = newValue
                                if newValue {
                                    live?.start(consuming: session, settings: benchmark)
                                } else {
                                    live?.stop()
                                }
                            }
                        )) {
                            Label("Live", systemImage: "sparkles.tv")
                        }
                        .toggleStyle(.button)
                        .disabled(benchmark.loadState != .loaded)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "style: %.2f", styleStrength))
                                .font(.caption)
                            Slider(value: $styleStrength, in: 0...1)
                                .frame(width: 160)
                        }
                        Picker("stylize", selection: $maskMode) {
                            ForEach(MaskMode.allCases) { m in
                                Text(m.label).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .help("Where the AI layer is applied. Background = repaint the room while keeping the person as live camera.")
                        Toggle("pose modifier", isOn: Binding(
                            get: { benchmark.composer.enablePoseModifier },
                            set: { benchmark.composer.enablePoseModifier = $0 }
                        ))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                        Toggle("motion modifier", isOn: Binding(
                            get: { benchmark.composer.enableMotionModifier },
                            set: { benchmark.composer.enableMotionModifier = $0 }
                        ))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                    }

                    HStack(spacing: 12) {
                        Picker("resolution", selection: $benchmark.variant) {
                            ForEach(ModelVariant.allCases) { v in
                                Text(v.label).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(liveOn || benchmark.loadState == .loading)

                        Picker("compute", selection: $benchmark.computeUnits) {
                            ForEach(ComputeUnitChoice.allCases) { c in
                                Text(c.label).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .disabled(liveOn || benchmark.loadState == .loading)
                    }
                    .font(.caption)

                    benchmarkStatusText
                    liveStatusText
                    effectivePromptText
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

    @ViewBuilder
    private var liveStatusText: some View {
        if let live, liveOn {
            let ms = live.smoothedSeconds * 1000.0
            let fps = live.smoothedSeconds > 0 ? 1.0 / live.smoothedSeconds : 0
            let line: String = {
                switch live.status {
                case .idle: return "live: idle"
                case .waitingForModel: return "live: model not loaded"
                case .running:
                    return String(format: "live: %.0f ms / pass (%.2f Hz) · %d passes",
                                  ms, fps, live.passCount)
                case .stalled(let r): return "live: stalled (\(r))"
                case .failed(let m): return "live: error \(m)"
                }
            }()
            Text(line)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.cyan)
        }
    }

    // MARK: - PromptKit (M4)

    @ViewBuilder
    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(StylePresets.all) { preset in
                    let selected = benchmark.composer.preset.id == preset.id
                    Button {
                        benchmark.composer.preset = preset
                        benchmark.stepCount = preset.suggestedSteps
                        benchmark.strength = preset.suggestedStrength
                    } label: {
                        Label(preset.name, systemImage: preset.symbol)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.accentColor.opacity(0.6)
                                           : Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Color.accentColor : .clear,
                                    lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxHeight: 32)
    }

    @ViewBuilder
    private var effectivePromptText: some View {
        // Trigger SwiftUI to recompute on any of the inputs the composer uses.
        let _ = vision.passCount
        let _ = benchmark.composer.preset.id
        let _ = benchmark.composer.enablePoseModifier
        let _ = benchmark.composer.enableMotionModifier
        let comp = benchmark.composer.compose(with: benchmark.latestVisionFrame)
        VStack(alignment: .leading, spacing: 2) {
            Text("→ \(comp.prompt)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                if let p = comp.poseHint {
                    Label(p, systemImage: "figure.wave")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if let m = comp.motionHint {
                    Label(m, systemImage: "wind")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func toggleFullscreen() {
        guard let window = NSApplication.shared.keyWindow
              ?? NSApplication.shared.windows.first
        else { return }
        window.toggleFullScreen(nil)
    }
}

#Preview {
    ContentView()
}
