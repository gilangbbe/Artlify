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
    /// Local audio file player. When a file is loaded, it owns the
    /// karaoke timeline (sample-accurate) and feeds the reactor
    /// directly, bypassing mic / SCK.
    @State private var audioFile = AudioFilePlayer()
    /// Apple Music driver. When `musicKit.isActive` is true, it owns
    /// the karaoke timeline (`musicKit.currentTime` is polled from
    /// `ApplicationMusicPlayer.shared.playbackTime`). Audio analysis
    /// still comes from the mic listening to the speakers —
    /// `ApplicationMusicPlayer` doesn't expose buffers to our process.
    @State private var musicKit = MusicKitPlayer()
    @State private var showVisionOverlay = false
    @State private var showHUD = true
    /// Drives the random negative-camera flashes around body parts.
    /// Tick rate is intentionally slow (~9 Hz) so flashes feel
    /// stuttery and intentional rather than continuous noise.
    @State private var boxTimer = Timer.publish(every: 0.11, on: .main, in: .common).autoconnect()
    /// Last time we fired an ASCII shockwave (rate-limit transients).
    @State private var lastAsciiShock: CFAbsoluteTime = 0
    @State private var blobs = BlobBoxStore()
    @State private var blobsEnabled: Bool = true
    @State private var blobsIntensity: Double = 1.0
    @State private var blobsStrings: Bool = true
    @State private var karaoke = KaraokeStore()
    @State private var karaokeEnabled: Bool = false
    /// When false, KaraokeOverlay's loud layer-3 (chromatic + chaos
    /// current-line text) is suppressed while the quieter layers (world
    /// fragments, prev/next satellites, slice tear, bloom) keep running.
    @State private var karaokeCurrentLineEnabled: Bool = true
    @State private var karaokePlaying: Bool = false
    /// Wall-clock time of the last karaoke advance tick, used to
    /// integrate `karaoke.currentTime` at 1× between repaints.
    @State private var karaokeLastTick: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    /// 60 Hz clock for advancing the karaoke playhead. Independent of
    /// the Vision / Metal clocks so the lyric scrub stays smooth even
    /// when the camera pipeline hiccups.
    @State private var karaokeTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    /// Phase 2: head-tethered lyric blob. Independent toggle from the
    /// main karaoke overlay so the user can pick fixed (bottom)
    /// karaoke, head-anchored karaoke, or both at once.
    @State private var headBlobEnabled: Bool = false
    /// Phase 2 UI slice: music search sheet. Opens from the karaoke
    /// row. Backed by `MockMusicCatalog` until LRCLIB lands.
    @State private var showMusicSearch: Bool = false
    /// Title of the currently-loaded track, surfaced in the HUD as a
    /// "now playing" caption so the user can tell *what* the karaoke
    /// engine is scrubbing through.
    @State private var currentTrackTitle: String? = nil
    @State private var asciiHue: Double = 0.33   // green default

    /// Open-hand gesture → full-screen negative-camera flash. When
    /// on, Vision runs `VNDetectHumanHandPoseRequest` alongside body
    /// pose; whenever a hand opens (rising edge), the renderer kicks
    /// a fade-in of the inverted live camera over the stylised scene.
    @State private var negFlashEnabled: Bool = false
    /// Current 0…1 flash envelope. Kicked to `negFlashPeak` on a
    /// rising-edge open-hand and decayed each frame so the flash
    /// blooms in and out by itself.
    @State private var negFlashIntensity: Float = 0
    /// Peak opacity reached on trigger (0…1). 1.0 = full inversion
    /// pop; lower values feel like a soft strobe over the scene.
    @State private var negFlashPeak: Double = 1.0
    /// Per-frame decay multiplier (0…1). Higher = slower fade.
    /// 0.92 ≈ 0.4 s half-life at 60 Hz; 0.97 ≈ 1.5 s.
    @State private var negFlashFade: Double = 0.92
    /// Hue of the tint multiplied onto the inverted image (0…1).
    /// Saturation 0 → the slider is ignored and the flash stays a
    /// pure photo-negative; >0 starts colouring the inversion.
    @State private var negFlashHue: Double = 0.08         // amber default
    @State private var negFlashSaturation: Double = 0.0   // off by default → pure inversion
    /// True while the last Vision pass reported an open hand — used
    /// for rising-edge detection so a held-open palm fires once, not
    /// every frame.
    @State private var handWasOpen: Bool = false
    /// Wall-clock of the last flash kick; rate-limits to one flash
    /// per ~0.55 s so a slow open-close-open doesn't strobe.
    @State private var negFlashLastTrigger: CFAbsoluteTime = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraMetalView(renderer: session.renderer)
                .ignoresSafeArea()

            if blobsEnabled {
                GeometryReader { proxy in
                    BlobBoxesOverlay(store: blobs,
                                     intensity: blobsIntensity,
                                     drawStrings: blobsStrings)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()
            }

            if karaokeEnabled {
                GeometryReader { proxy in
                    KaraokeOverlay(store: karaoke,
                                   showCurrentLine: karaokeCurrentLineEnabled,
                                   audioLevel: Double(audio.latest.level),
                                   audioLow: Double(audio.latest.low),
                                   audioMid: Double(audio.latest.mid),
                                   audioHigh: Double(audio.latest.high),
                                   audioTransient: Double(audio.latest.transient))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()
            }

            if headBlobEnabled {
                GeometryReader { proxy in
                    HeadLyricBlob(store: karaoke,
                                  frame: vision.latestFrame,
                                  audioLevel: Double(audio.latest.level),
                                  audioLow: Double(audio.latest.low),
                                  audioMid: Double(audio.latest.mid),
                                  audioHigh: Double(audio.latest.high),
                                  audioTransient: Double(audio.latest.transient))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()
            }

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

            // Wire the file player's tap into the reactor's analysis
            // pipeline. Always-on hook — the reactor's `ingest` no-ops
            // unless its source is `.audioFile`, so it's safe to leave
            // connected even when the user's listening to mic / SCK.
            audioFile.onAudioBuffer = { [audio] buffer in
                audio.ingest(buffer: buffer)
            }
            audioFile.onFinished = {
                // Karaoke caught up to end-of-track; flip transport
                // state so the HUD reads paused instead of "playing"
                // forever after the last frame drains.
                karaokePlaying = false
            }

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
            musicKit.stop()
            audioFile.stop()
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
            // Push fresh joint samples into the blob-box store so
            // each tracked body point's bounding box follows the body.
            updateBlobs()
            // Open-hand gesture → kick the negative-flash envelope on
            // the rising edge (closed/absent → open transition). The
            // envelope itself decays on the karaoke 60 Hz timer below.
            if negFlashEnabled {
                let isOpen = vision.latestFrame?.handOpen != nil
                if isOpen, !handWasOpen {
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - negFlashLastTrigger > 0.55 {
                        negFlashIntensity = Float(negFlashPeak)
                        negFlashLastTrigger = now
                    }
                }
                handWasOpen = isOpen
            }
        }
        // Periodically flash 1–3 negative-camera boxes around random
        // body joints. Empty frames (no joints) are silently skipped.
        .onReceive(boxTimer) { _ in
            tickNegativeBoxes()
            tickAsciiShockwave()
            if blobsEnabled {
                blobs.tickFlash(now: CFAbsoluteTimeGetCurrent())
            }
        }
        // Advance the karaoke playhead at 1× when playing. Driven by
        // wall-clock deltas so pauses / drops don't desync the lyrics.
        .onReceive(karaokeTimer) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let dt = now - karaokeLastTick
            karaokeLastTick = now
            // Decay the negative-flash envelope independent of the
            // karaoke transport so the flash blooms even with no song
            // loaded. Multiplier 0.92 @ 60 Hz \u2248 0.4 s to 1% \u2014 long
            // enough to read clearly, short enough not to overstay.
            if negFlashEnabled {
                negFlashIntensity *= Float(negFlashFade)
                if negFlashIntensity < 0.002 { negFlashIntensity = 0 }
                session.renderer.setNegFlash(intensity: negFlashIntensity)
            }
            guard karaokeEnabled else { return }
            // Priority order for who owns the timeline:
            //   1. MusicKit  (Apple Music — polled from daemon)
            //   2. AudioFile (local file — sample-accurate)
            //   3. Wall-clock integrator (sample LRC / demo rows)
            if musicKit.isActive {
                // Track may be nil (song without LRC). Clamp only
                // when we have a track, otherwise let the playhead
                // run freely so the timecode still ticks for visitors.
                if let track = karaoke.track {
                    karaoke.currentTime = min(musicKit.currentTime, track.duration)
                } else {
                    karaoke.currentTime = musicKit.currentTime
                }
                // Mirror transport so the HUD play/pause icon tracks
                // what the system player is actually doing.
                if karaokePlaying != musicKit.isPlaying {
                    karaokePlaying = musicKit.isPlaying
                }
                return
            }
            guard karaoke.track != nil else { return }
            // If a local file is loaded, the player owns time —
            // sample-accurate, immune to drift / pauses / seeks. Just
            // mirror its `currentTime` into the karaoke store.
            if audioFile.fileURL != nil {
                karaoke.currentTime = min(audioFile.currentTime,
                                          karaoke.track!.duration)
            } else if karaokePlaying {
                karaoke.currentTime = min(karaoke.currentTime + dt,
                                          karaoke.track!.duration)
            }
        }
        // Keyboard: H toggles the HUD for clean recordings.
        .background(KeyHandler { key in
            if key.lowercased() == "h" { showHUD.toggle() }
        })
        // Music search sheet (phase 2 UI slice). Mock catalog today;
        // swaps to MusicCatalogSearchRequest + LRCLIB later without
        // touching this presentation.
        .sheet(isPresented: $showMusicSearch) {
            MusicSearchSheet(
                onSelect: { result in
                    switch result.kind {
                    case .demo, .lrclib:
                        // Stop any Apple Music playback first so the
                        // user doesn't hear two sources fighting.
                        musicKit.stop()
                        karaoke.track = LRCParser.parse(result.lrc)
                        karaoke.currentTime = 0
                        currentTrackTitle = result.title
                        karaokeEnabled = true
                        karaokePlaying = true
                        karaokeLastTick = CFAbsoluteTimeGetCurrent()
                    case .appleMusic(let song):
                        // Switch ownership: stop local file player so
                        // we don't get two audio sources mixing.
                        audioFile.stop()
                        // Make sure the mic is running — analysis path
                        // for ApplicationMusicPlayer is "listen to the
                        // speakers" since the daemon doesn't expose
                        // buffers to our process.
                        if audio.source != .microphone {
                            audio.switchSource(.microphone)
                        }
                        if !audio.isRunning { audio.start() }
                        currentTrackTitle = result.title
                        karaokeEnabled = true
                        karaokePlaying = true
                        karaokeLastTick = CFAbsoluteTimeGetCurrent()
                        // Optimistically clear any previous lyrics so
                        // the overlay shows a clean state until the
                        // LRCLIB fetch lands.
                        karaoke.clear()
                        Task { @MainActor in
                            await musicKit.play(song: song)
                            // Try to fetch synced lyrics by title + artist.
                            // Best-effort — if LRCLIB has nothing, the
                            // song still plays, just without lyrics.
                            let hits = (try? await LRCLibClient.search(
                                track: result.title,
                                artist: result.artist
                            )) ?? []
                            if let synced = hits.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics {
                                karaoke.track = LRCParser.parse(synced)
                            }
                        }
                    }
                },
                onClose: { showMusicSearch = false }
            )
        }
    }

    // MARK: - Top-left status

    @ViewBuilder
    private var statusHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                    .frame(width: 8, height: 8)
                Text("ARTLIFY")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .tracking(2.4)
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let device = session.activeDeviceName {
                Text("device  ·  \(device)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        )
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
                    .frame(width: 120)
                Text(String(format: "%.0f", session.renderer.asciiCellSize) + " px")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("hue")
                    .font(.caption)
                Slider(value: Binding(
                    get: { asciiHue },
                    set: { newVal in
                        asciiHue = newVal
                        applyAsciiHue(newVal)
                    }
                ), in: 0...1)
                    .frame(width: 110)
                Circle()
                    .fill(Color(hue: asciiHue, saturation: 0.7, brightness: 1.0))
                    .frame(width: 14, height: 14)
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

            HStack(spacing: 12) {
                Toggle("blobs", isOn: $blobsEnabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .onChange(of: blobsEnabled) { _, on in
                        if !on { blobs.clear() }
                    }
                Toggle("strings", isOn: $blobsStrings)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Text("flash")
                    .font(.caption)
                Slider(value: Binding(
                    get: { blobs.flashProbability },
                    set: { blobs.flashProbability = $0 }
                ), in: 0.05...0.8)
                    .frame(width: 110)
                Text(String(format: "%.2f", blobs.flashProbability))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("intensity")
                    .font(.caption)
                Slider(value: $blobsIntensity, in: 0.2...1.5)
                    .frame(width: 110)
                Text(String(format: "%.2f", blobsIntensity))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            karaokeRow

            negFlashCard

            HStack(spacing: 12) {
                Toggle("layer 3 lyric", isOn: $karaokeCurrentLineEnabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Toggle the big chromatic current-line text in the karaoke overlay. Off keeps the quieter background layers.")
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
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.40), radius: 16, x: 0, y: 6)
        )
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Karaoke HUD row (stage 1: sample LRC + scrub slider)

    @ViewBuilder
    private var karaokeRow: some View {
        HStack(spacing: 12) {
            Toggle("karaoke", isOn: $karaokeEnabled)
                .toggleStyle(.button)
                .controlSize(.small)
                .onChange(of: karaokeEnabled) { _, on in
                    if !on { karaokePlaying = false }
                }
            Toggle("head blob", isOn: $headBlobEnabled)
                .toggleStyle(.button)
                .controlSize(.small)
            Button {
                showMusicSearch = true
            } label: {
                Label("search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                // Load a local audio file. When one is loaded, the
                // player owns the karaoke timeline (sample-accurate)
                // and the reactor receives its samples directly via
                // the tap installed in `AudioFilePlayer.load`.
                guard let url = AudioFilePlayer.runOpenPanel() else { return }
                do {
                    // Stop Apple Music first so we don't get two
                    // sources fighting over the speakers.
                    musicKit.stop()
                    try audioFile.load(url: url)
                    audio.switchSource(.audioFile)
                    if !audio.isRunning { audio.start() }
                    karaokeEnabled = true
                    karaokePlaying = true
                    audioFile.play()
                    if karaoke.track == nil {
                        karaoke.loadSample()
                    }
                    currentTrackTitle = audioFile.fileName
                    karaokeLastTick = CFAbsoluteTimeGetCurrent()
                } catch {
                    // Surface the failure into the now-playing pill
                    // so the user sees *something* changed.
                    currentTrackTitle = "⚠︎ \(error.localizedDescription)"
                }
            } label: {
                Label("file", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                karaoke.loadSample()
                currentTrackTitle = karaoke.track?.title ?? "Sample"
                karaokeEnabled = true
                karaokePlaying = true
                karaokeLastTick = CFAbsoluteTimeGetCurrent()
            } label: {
                Label("sample", systemImage: "music.note.list")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                karaokePlaying.toggle()
                karaokeLastTick = CFAbsoluteTimeGetCurrent()
                // Mirror onto whichever player owns the timeline.
                if musicKit.isActive {
                    if karaokePlaying { musicKit.resume() }
                    else              { musicKit.pause() }
                } else if audioFile.fileURL != nil {
                    if karaokePlaying { audioFile.play() }
                    else              { audioFile.pause() }
                }
            } label: {
                Image(systemName: karaokePlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(karaoke.track == nil && !musicKit.isActive)
            Button {
                // Stop + eject — clear the loaded track so the user
                // can see the row reset, useful between demos.
                karaokePlaying = false
                musicKit.stop()
                audioFile.stop()
                karaoke.clear()
                currentTrackTitle = nil
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(karaoke.track == nil && !musicKit.isActive)
            // Scrub slider — present even with no track so the row
            // doesn't reflow when one is loaded; greyed by `disabled`.
            Slider(value: Binding(
                get: {
                    if musicKit.isActive { return musicKit.currentTime }
                    return karaoke.currentTime
                },
                set: { newVal in
                    karaoke.currentTime = newVal
                    // Seek whichever player owns the timeline.
                    if musicKit.isActive {
                        musicKit.seek(to: newVal)
                    } else if audioFile.fileURL != nil {
                        audioFile.seek(to: newVal)
                    }
                }
            ), in: 0...max(0.01,
                           musicKit.isActive
                           ? max(musicKit.duration, karaoke.track?.duration ?? 0)
                           : (karaoke.track?.duration ?? 0.01)))
                .frame(width: 220)
                .disabled(karaoke.track == nil && !musicKit.isActive)
            Text(timecode(musicKit.isActive ? musicKit.currentTime : karaoke.currentTime))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if musicKit.isActive, musicKit.duration > 0 {
                Text("/ \(timecode(musicKit.duration))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else if let t = karaoke.track {
                Text("/ \(timecode(t.duration))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let title = currentTrackTitle {
                // Now-playing badge — small, dimmed, with a marquee
                // dot to signal liveness without flicker.
                HStack(spacing: 4) {
                    Circle()
                        .fill(karaokePlaying ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
            }
            Spacer()
        }
    }

    private func timecode(_ t: TimeInterval) -> String {
        let secs = max(0, t)
        let mm = Int(secs) / 60
        let ss = Int(secs) % 60
        return String(format: "%d:%02d", mm, ss)
    }

    // MARK: - Negative-flash gesture card

    /// Convert the HUD's hue + saturation knobs into an RGB multiplier
    /// for the inverted image. Saturation 0 collapses to (1,1,1) which
    /// gives a pure photo-negative; >0 begins colour-tinting the flash.
    private var negFlashTint: SIMD3<Float> {
        let c = Color(hue: negFlashHue,
                      saturation: negFlashSaturation,
                      brightness: 1.0)
        let ns = NSColor(c).usingColorSpace(.deviceRGB) ?? NSColor.white
        return SIMD3<Float>(Float(ns.redComponent),
                            Float(ns.greenComponent),
                            Float(ns.blueComponent))
    }

    /// Push the latest tint to the renderer and re-emit the current
    /// envelope so the live frame reflects the new colour immediately.
    private func pushNegFlashTint() {
        session.renderer.negFlashTint = negFlashTint
        session.renderer.setNegFlash(intensity: negFlashIntensity)
    }

    @ViewBuilder
    private var negFlashCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption)
                    .foregroundStyle(negFlashEnabled ? .orange : .secondary)
                Text("OPEN-HAND FLASH")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $negFlashEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Open hand → full-screen negative-camera flash. Vision must run hand-pose alongside body pose; off by default to save Vision cost.")
                    .onChange(of: negFlashEnabled) { _, on in
                        vision.setHandPoseEnabled(on)
                        session.renderer.negFlashEnabled = on
                        if on {
                            pushNegFlashTint()
                        } else {
                            handWasOpen = false
                            negFlashIntensity = 0
                            session.renderer.setNegFlash(intensity: 0)
                        }
                    }
            }

            if negFlashEnabled {
                HStack(spacing: 14) {
                    flashSlider(label: "peak",
                                value: $negFlashPeak,
                                range: 0.2...1.0,
                                fmt: "%.2f")
                    flashSlider(label: "fade",
                                value: $negFlashFade,
                                range: 0.80...0.985,
                                fmt: "%.3f")
                    flashSlider(label: "hue",
                                value: $negFlashHue,
                                range: 0...1,
                                fmt: "%.2f")
                        .onChange(of: negFlashHue) { _, _ in pushNegFlashTint() }
                    flashSlider(label: "tint",
                                value: $negFlashSaturation,
                                range: 0...1,
                                fmt: "%.2f")
                        .onChange(of: negFlashSaturation) { _, _ in pushNegFlashTint() }
                    Circle()
                        .fill(Color(hue: negFlashHue,
                                    saturation: negFlashSaturation,
                                    brightness: 1.0))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                    Button {
                        negFlashIntensity = Float(negFlashPeak)
                        session.renderer.setNegFlash(intensity: negFlashIntensity)
                    } label: {
                        Label("test", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Manually trigger the flash without needing the gesture.")
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func flashSlider(label: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
                .frame(width: 110)
        }
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

            // Source picker (mic vs system audio). Flipping while the
            // reactor is running swaps cleanly; flipping while it's
            // off just stores the choice for the next start.
            Picker("source", selection: Binding(
                get: { audio.source },
                set: { audio.switchSource($0) }
            )) {
                Image(systemName: "mic.fill")
                    .tag(AudioReactor.InputSource.microphone)
                Image(systemName: "music.note")
                    .tag(AudioReactor.InputSource.audioFile)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            .help(audio.source == .microphone
                  ? "Listening to microphone (point it at your speakers for music)"
                  : "Listening to loaded audio file")

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

    // MARK: - Blob-box driver

    /// Pull confident joints from the latest Vision frame, flip
    /// Vision's bottom-left y to top-left uv, push positions into the
    /// store. The flash gate is driven separately on the box timer.
    private func updateBlobs() {
        guard blobsEnabled, let f = vision.latestFrame else { return }
        let samples: [(id: String, uv: SIMD2<Float>)] = f.joints
            .filter { $0.confidence >= 0.4 }
            .map { j in
                (id: j.id,
                 uv: SIMD2<Float>(Float(j.point.x),
                                  Float(1.0 - j.point.y)))
            }
        blobs.updatePositions(joints: samples,
                              now: CFAbsoluteTime(f.timestamp))
    }

    /// Map a single hue slider into the ASCII shader's two tint colours
    /// (low = darker / more saturated, high = brighter / lighter).
    private func applyAsciiHue(_ hue: Double) {
        let lowNS  = NSColor(hue: CGFloat(hue), saturation: 0.85,
                             brightness: 0.95, alpha: 1.0)
        let highNS = NSColor(hue: CGFloat(hue), saturation: 0.35,
                             brightness: 1.00, alpha: 1.0)
        if let l = lowNS.usingColorSpace(.deviceRGB),
           let h = highNS.usingColorSpace(.deviceRGB) {
            session.renderer.asciiColorLow = SIMD3<Float>(
                Float(l.redComponent), Float(l.greenComponent), Float(l.blueComponent)
            )
            session.renderer.asciiColorHigh = SIMD3<Float>(
                Float(h.redComponent), Float(h.greenComponent), Float(h.blueComponent)
            )
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
