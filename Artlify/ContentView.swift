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

    // MARK: - Background controls

    /// Solid colour scrim drawn between the camera layer and the
    /// foreground overlays. At `bgOpacity == 0` it does nothing;
    /// dialled up it fades the live camera toward this colour without
    /// affecting Vision or the overlays riding above it.
    @State private var bgColor: Color = .black
    /// 0… 1 alpha of the background scrim. Default 0 → camera is
    /// untouched out of the box.
    @State private var bgOpacity: Double = 0

    /// Toggleable counter-depth ASCII environment that sits BEHIND
    /// every foreground overlay but in front of the camera scrim.
    /// See `AsciiDepthBackground` for the depth-field details.
    @State private var asciiDepthEnabled: Bool = false
    @State private var asciiDepthHue: Double = 0.55         // phosphor cyan
    @State private var asciiDepthSaturation: Double = 0.65
    @State private var asciiDepthBrightness: Double = 0.85
    @State private var asciiDepthDensity: Double = 0.45
    @State private var asciiDepthCollapse: Double = 0.75
    /// Master gain on the counter-depth audio reactivity. 0
    /// disables audio-driven modulation entirely; 1 lets the bass
    /// pump the tunnel, transients flash glitches, and treble
    /// sweep the hue. Default 0.6 reads as "clearly grooving"
    /// without overwhelming the static depth field.
    @State private var asciiDepthReactivity: Double = 0.6

    /// Scene-aware ASCII depth pass. Builds a monocular-depth proxy
    /// from (person mask + edges + vertical falloff + luma) and
    /// renders the scene as typographic density layers. See
    /// `DepthAsciiScene` for the analyzer + renderer.
    @State private var depthAscii = DepthAsciiScene()
    @State private var depthAsciiEnabled: Bool = false
    @State private var depthAsciiIntensity: Double = 0.85
    @State private var depthAsciiDensity: Double = 0.92
    @State private var depthAsciiNearHue: Double = 0.08   // warm amber
    @State private var depthAsciiFarHue: Double = 0.58    // cool indigo
    @State private var depthAsciiContourBoost: Double = 1.3
    @State private var depthAsciiWordRate: Double = 0.25

    /// Pop-over presentation flags for the two production-ready
    /// menus exposed from the top bar. Replaces the three loose
    /// HUD cards (status / background / particle) that collided
    /// at small window sizes with one bar + two on-demand menus.
    @State private var showArtMenu: Bool = false
    @State private var showMusicMenu: Bool = false

    /// User-managed playlist that drives auto-advance between
    /// tracks. Every load action (Search sheet, Open File, Sample)
    /// appends here and starts the queue if nothing else is playing.
    @State private var queue = MusicQueue()

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraMetalView(renderer: session.renderer)
                .ignoresSafeArea()

            // Solid-colour scrim between camera and overlays. Drawn
            // before the ASCII background so dialling up `bgOpacity`
            // mutes the camera underneath the depth field rather
            // than tinting through it.
            if bgOpacity > 0.001 {
                bgColor
                    .opacity(bgOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Counter-depth ASCII background. Hollow centre, dense
            // rushing edges, pulsing outward — reads as inside-out
            // space whose vanishing point is on YOUR side of the
            // screen.
            if asciiDepthEnabled {
                AsciiDepthBackground(
                    hue: asciiDepthHue,
                    saturation: asciiDepthSaturation,
                    brightness: asciiDepthBrightness,
                    density: asciiDepthDensity,
                    collapse: asciiDepthCollapse,
                    audioLevel: Double(audio.latest.level),
                    audioLow: Double(audio.latest.low),
                    audioMid: Double(audio.latest.mid),
                    audioHigh: Double(audio.latest.high),
                    audioTransient: Double(audio.latest.transient),
                    reactivity: asciiDepthReactivity
                )
                .ignoresSafeArea()
            }

            // Scene-aware ASCII depth pass — camera-driven, sits
            // above the procedural counter-depth bg so its typographic
            // structure reads against the field, but below interactive
            // overlays so blobs/karaoke/HUD remain crisp on top.
            if depthAsciiEnabled {
                DepthAsciiSceneOverlay(
                    scene: depthAscii,
                    intensity: depthAsciiIntensity,
                    density: depthAsciiDensity,
                    nearHue: depthAsciiNearHue,
                    farHue: depthAsciiFarHue,
                    wordRate: depthAsciiWordRate,
                    contourBoost: depthAsciiContourBoost
                )
            }

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
                topBar(field: field)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color.black)
        .onAppear {
            session.start()
            vision.start(consuming: session)
            depthAscii.start(session: session, vision: vision)

            // Wire the file player's tap into the reactor's analysis
            // pipeline. Always-on hook — the reactor's `ingest` no-ops
            // unless its source is `.audioFile`, so it's safe to leave
            // connected even when the user's listening to mic / SCK.
            audioFile.onAudioBuffer = { [audio] buffer in
                audio.ingest(buffer: buffer)
            }
            audioFile.onFinished = {
                // Karaoke caught up to end-of-track. Try to advance
                // the queue to the next item; if the queue is empty
                // (or this track wasn't queue-driven), flip transport
                // state so the HUD reads paused.
                if !playNextInQueue() {
                    karaokePlaying = false
                }
            }
            musicKit.onFinished = {
                if !playNextInQueue() {
                    karaokePlaying = false
                }
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
            depthAscii.stop()
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
                    enqueueSearchResult(result)
                },
                onClose: { showMusicSearch = false }
            )
        }
    }

    // MARK: - Top bar HUD (production layout)

    /// Single thin bar pinned to the top of the window. Replaces the
    /// earlier collection of three free-floating cards (status / bg /
    /// particle) so panels can never collide and the live image stays
    /// uncluttered. Status info on the left, toolbar buttons on the
    /// right; the heavy controls live behind two popovers (`Art` and
    /// `Music`) opened from this bar.
    @ViewBuilder
    private func topBar(field: ParticleField?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                statusPill
                Spacer(minLength: 8)
                toolbarButtons(field: field)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .frame(height: 0.5)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
            )
            Spacer()
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(.white)
    }

    /// Left-aligned ARTLIFY brand + live status + active device + a
    /// now-playing pill so the user can read transport state at a
    /// glance without opening the music menu.
    @ViewBuilder
    private var statusPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
                .frame(width: 8, height: 8)
            Text("ARTLIFY")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(2.4)
            Text(statusText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let device = session.activeDeviceName {
                Text("·").foregroundStyle(.tertiary)
                Text(device)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
            }
            visionStatusLine
            if let title = currentTrackTitle {
                HStack(spacing: 4) {
                    Circle()
                        .fill(karaokePlaying ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
            }
        }
    }

    /// Right-aligned button cluster: camera picker, Art popover,
    /// Music popover, Vision overlay toggle, fullscreen, hide-HUD.
    /// Every heavy control lives behind one of the two popovers so
    /// the bar itself stays one row tall at any window size.
    @ViewBuilder
    private func toolbarButtons(field: ParticleField?) -> some View {
        HStack(spacing: 8) {
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
                    Divider()
                    Button {
                        session.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label("Camera", systemImage: "camera.rotate")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            }

            Button {
                showArtMenu.toggle()
            } label: {
                Label("Art", systemImage: "paintpalette.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showArtMenu, arrowEdge: .top) {
                artMenuContent(field: field)
                    .frame(width: 560, height: 660)
            }

            Button {
                showMusicMenu.toggle()
            } label: {
                Label("Music", systemImage: "music.note.list")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $showMusicMenu, arrowEdge: .top) {
                musicMenuContent
                    .frame(width: 600, height: 620)
            }

            Toggle(isOn: $showVisionOverlay) {
                Image(systemName: "figure.stand")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle Vision pose overlay (joints + skeleton)")

            Button {
                toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle fullscreen")

            Button {
                showHUD = false
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Hide HUD (press H to bring it back)")
        }
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

    // MARK: - Art menu (popover content)

    /// Full art-controls menu shown inside the Art popover. Every
    /// visual subsystem (background scrim, ASCII depth field,
    /// particle field, trails, silhouette ASCII, neg boxes, blobs,
    /// open-hand flash, audio reactor, karaoke layers) gets its own
    /// section card so the user can scroll without losing context
    /// of which subsystem they're tuning.
    @ViewBuilder
    private func artMenuContent(field: ParticleField?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(.orange)
                Text("ART CONTROLS")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .tracking(1.4)
                Spacer()
                Text("press H to hide HUD")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    backgroundSection
                    asciiDepthSection
                    depthAsciiSection
                    if let field { particleSection(field: field) }
                    trailsSection
                    silhouetteAsciiSection
                    negBoxesSection
                    blobsSection
                    negFlashCard
                    if let field { audioSection(field: field) }
                }
                .padding(14)
            }
        }
        .background(.background)
    }

    /// Lightweight per-section card wrapper used inside the Art
    /// menu. Mirrors the chrome of `negFlashCard` so every section
    /// reads as part of one family.
    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
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
    private var backgroundSection: some View {
        sectionCard(title: "BACKGROUND SCRIM", icon: "rectangle.fill") {
            HStack(spacing: 10) {
                ColorPicker("color",
                            selection: $bgColor,
                            supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 18)
                flashSlider(label: "opacity",
                            value: $bgOpacity,
                            range: 0...1,
                            fmt: "%.2f")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var asciiDepthSection: some View {
        sectionCard(title: "ASCII COUNTER-DEPTH", icon: "scope") {
            HStack {
                Toggle("enabled", isOn: $asciiDepthEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
            }
            if asciiDepthEnabled {
                HStack(spacing: 14) {
                    flashSlider(label: "hue",
                                value: $asciiDepthHue,
                                range: 0...1, fmt: "%.2f")
                    flashSlider(label: "sat",
                                value: $asciiDepthSaturation,
                                range: 0...1, fmt: "%.2f")
                    Circle()
                        .fill(Color(hue: asciiDepthHue,
                                    saturation: asciiDepthSaturation,
                                    brightness: 1.0))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                }
                HStack(spacing: 14) {
                    flashSlider(label: "bright",
                                value: $asciiDepthBrightness,
                                range: 0...1, fmt: "%.2f")
                    flashSlider(label: "density",
                                value: $asciiDepthDensity,
                                range: 0...1, fmt: "%.2f")
                    flashSlider(label: "collapse",
                                value: $asciiDepthCollapse,
                                range: 0...1, fmt: "%.2f")
                }
                HStack(spacing: 14) {
                    flashSlider(label: "audio",
                                value: $asciiDepthReactivity,
                                range: 0...1, fmt: "%.2f")
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var depthAsciiSection: some View {
        sectionCard(title: "ASCII SCENE DEPTH", icon: "square.stack.3d.up.fill") {
            HStack {
                Toggle("enabled", isOn: $depthAsciiEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                Text("heuristic depth · person+edges+falloff")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if depthAsciiEnabled {
                HStack(spacing: 14) {
                    flashSlider(label: "intensity",
                                value: $depthAsciiIntensity,
                                range: 0...1, fmt: "%.2f")
                    flashSlider(label: "density",
                                value: $depthAsciiDensity,
                                range: 0...1, fmt: "%.2f")
                }
                HStack(spacing: 14) {
                    flashSlider(label: "near hue",
                                value: $depthAsciiNearHue,
                                range: 0...1, fmt: "%.2f")
                    flashSlider(label: "far hue",
                                value: $depthAsciiFarHue,
                                range: 0...1, fmt: "%.2f")
                    Circle()
                        .fill(LinearGradient(
                            colors: [
                                Color(hue: depthAsciiNearHue,
                                      saturation: 0.55, brightness: 1.0),
                                Color(hue: depthAsciiFarHue,
                                      saturation: 0.45, brightness: 0.80)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                }
                HStack(spacing: 14) {
                    flashSlider(label: "contour",
                                value: $depthAsciiContourBoost,
                                range: 0...3, fmt: "%.2f")
                    flashSlider(label: "fog text",
                                value: $depthAsciiWordRate,
                                range: 0...1, fmt: "%.2f")
                }
            }
        }
    }

    @ViewBuilder
    private func particleSection(field: ParticleField) -> some View {
        sectionCard(title: "PARTICLE FIELD", icon: "circle.dotted") {
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
            HStack(spacing: 12) {
                slider(label: "attraction",
                       value: Binding(get: { field.attraction },
                                      set: { field.attraction = $0 }),
                       range: 0...5, fmt: "%.2f")
                slider(label: "flow",
                       value: Binding(get: { field.flow },
                                      set: { field.flow = $0 }),
                       range: 0...2, fmt: "%.2f")
            }
            HStack(spacing: 12) {
                slider(label: "swirl",
                       value: Binding(get: { field.flowScale },
                                      set: { field.flowScale = $0 }),
                       range: 1...20, fmt: "%.1f")
                slider(label: "damping",
                       value: Binding(get: { field.damping },
                                      set: { field.damping = $0 }),
                       range: 0.5...0.999, fmt: "%.3f")
            }
            HStack(spacing: 12) {
                slider(label: "size",
                       value: Binding(get: { field.pointSize },
                                      set: { field.pointSize = $0 }),
                       range: 1...14, fmt: "%.1f")
                slider(label: "glow",
                       value: Binding(get: { field.glow },
                                      set: { field.glow = $0 }),
                       range: 0.1...3, fmt: "%.2f")
            }
            HStack(spacing: 12) {
                slider(label: "hue",
                       value: Binding(get: { field.hueShift },
                                      set: { field.hueShift = $0 }),
                       range: 0...1, fmt: "%.2f")
                slider(label: "mask gate",
                       value: Binding(get: { field.maskGate },
                                      set: { field.maskGate = $0 }),
                       range: 0...1, fmt: "%.2f")
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
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var trailsSection: some View {
        sectionCard(title: "TRAILS", icon: "wind") {
            HStack(spacing: 12) {
                Toggle("enabled", isOn: Binding(
                    get: { session.renderer.trailsEnabled },
                    set: { session.renderer.trailsEnabled = $0 }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
                Text("decay")
                    .font(.caption)
                Slider(value: Binding(
                    get: { session.renderer.trailDecay },
                    set: { session.renderer.trailDecay = $0 }
                ), in: 0.80...0.995)
                    .frame(width: 160)
                Text(String(format: "%.3f", session.renderer.trailDecay))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var silhouetteAsciiSection: some View {
        sectionCard(title: "SILHOUETTE ASCII", icon: "textformat") {
            HStack(spacing: 12) {
                Toggle("enabled", isOn: Binding(
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
                    .frame(width: 110)
                Text(String(format: "%.0f px", session.renderer.asciiCellSize))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 12) {
                Text("hue")
                    .font(.caption)
                Slider(value: Binding(
                    get: { asciiHue },
                    set: { newVal in
                        asciiHue = newVal
                        applyAsciiHue(newVal)
                    }
                ), in: 0...1)
                    .frame(width: 140)
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
        }
    }

    @ViewBuilder
    private var negBoxesSection: some View {
        sectionCard(title: "NEG BOXES", icon: "square.dashed") {
            HStack(spacing: 12) {
                Toggle("enabled", isOn: Binding(
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
                    .frame(width: 160)
                Text(String(format: "%.2f", session.renderer.negativeBoxesPeak))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var blobsSection: some View {
        sectionCard(title: "BLOB BOXES", icon: "viewfinder") {
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
                Spacer()
            }
            HStack(spacing: 12) {
                Text("flash")
                    .font(.caption)
                Slider(value: Binding(
                    get: { blobs.flashProbability },
                    set: { blobs.flashProbability = $0 }
                ), in: 0.05...0.8)
                    .frame(width: 130)
                Text(String(format: "%.2f", blobs.flashProbability))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("intensity")
                    .font(.caption)
                Slider(value: $blobsIntensity, in: 0.2...1.5)
                    .frame(width: 130)
                Text(String(format: "%.2f", blobsIntensity))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func audioSection(field: ParticleField) -> some View {
        sectionCard(title: "AUDIO REACTOR", icon: "waveform") {
            audioRow(field: field)
        }
    }

    // MARK: - Music menu (popover content)

    /// Combined music + karaoke transport. Replaces the wide flat
    /// `karaokeRow` of the old HUD with a proper vertical layout:
    /// now-playing → loaders → transport → scrub → overlay toggles.
    /// Designed to fit cleanly inside a ~520×380 popover.
    @ViewBuilder
    private var musicMenuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.purple)
                Text("MUSIC & KARAOKE")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .tracking(1.4)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // Now-playing badge (full-width).
                HStack(spacing: 8) {
                    Circle()
                        .fill(karaokePlaying ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(currentTrackTitle ?? "No track loaded")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(currentTrackTitle == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }

                // Track loaders.
                HStack(spacing: 8) {
                    Button {
                        showMusicSearch = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        loadAudioFile()
                    } label: {
                        Label("Open File", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        let item = MusicQueueItem(
                            title: "Sample",
                            artist: nil,
                            duration: nil,
                            source: .sampleLRC)
                        enqueueAndStartIfIdle(item)
                    } label: {
                        Label("Sample", systemImage: "music.note")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }

                Divider().opacity(0.3)

                // Transport row.
                HStack(spacing: 12) {
                    Button {
                        karaokePlaying.toggle()
                        karaokeLastTick = CFAbsoluteTimeGetCurrent()
                        if musicKit.isActive {
                            if karaokePlaying { musicKit.resume() }
                            else              { musicKit.pause() }
                        } else if audioFile.fileURL != nil {
                            if karaokePlaying { audioFile.play() }
                            else              { audioFile.pause() }
                        }
                    } label: {
                        Image(systemName: karaokePlaying ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(karaoke.track == nil && !musicKit.isActive)
                    Button {
                        karaokePlaying = false
                        musicKit.stop()
                        audioFile.stop()
                        karaoke.clear()
                        currentTrackTitle = nil
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(karaoke.track == nil && !musicKit.isActive)

                    Text(timecode(musicKit.isActive ? musicKit.currentTime : karaoke.currentTime))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("/ \(timecode(trackDuration))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Slider(value: Binding(
                    get: {
                        if musicKit.isActive { return musicKit.currentTime }
                        return karaoke.currentTime
                    },
                    set: { newVal in
                        karaoke.currentTime = newVal
                        if musicKit.isActive {
                            musicKit.seek(to: newVal)
                        } else if audioFile.fileURL != nil {
                            audioFile.seek(to: newVal)
                        }
                    }
                ), in: 0...max(0.01, trackDuration))
                .disabled(karaoke.track == nil && !musicKit.isActive)

                Divider().opacity(0.3)

                // Up Next — user-managed playlist. Auto-advances
                // when the current track ends; tap a row to jump.
                queueSection

                Divider().opacity(0.3)

                // Karaoke overlay toggles.
                HStack(spacing: 8) {
                    Toggle("karaoke", isOn: $karaokeEnabled)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .onChange(of: karaokeEnabled) { _, on in
                            if !on { karaokePlaying = false }
                        }
                    Toggle("head blob", isOn: $headBlobEnabled)
                        .toggleStyle(.button)
                        .controlSize(.small)
                    Toggle("layer 3 lyric", isOn: $karaokeCurrentLineEnabled)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Toggle the big chromatic current-line text in the karaoke overlay.")
                    Spacer()
                }
            }
            .padding(14)
            Spacer()
        }
        .background(.background)
    }

    /// Convenience: total duration of whichever player owns the
    /// timeline. Falls back to a sentinel small value so the scrub
    /// slider stays a no-op (instead of crashing on a 0-length range)
    /// when nothing is loaded.
    private var trackDuration: TimeInterval {
        if musicKit.isActive {
            return max(musicKit.duration, karaoke.track?.duration ?? 0)
        }
        return karaoke.track?.duration ?? 0
    }

    /// Open-panel + load-file flow extracted from the old karaoke
    /// row so the music menu's "Open File" button can call the same
    /// path without duplicating the error-surfacing logic. Now feeds
    /// the file into the shared queue so it slots into auto-advance
    /// with everything else the user has loaded.
    private func loadAudioFile() {
        guard let url = AudioFilePlayer.runOpenPanel() else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let item = MusicQueueItem(
            title: title,
            artist: nil,
            duration: nil,
            source: .localFile(url))
        enqueueAndStartIfIdle(item)
    }

    // MARK: - Music queue dispatch

    /// Append to the queue and — if nothing is currently playing —
    /// immediately advance so the user hears it without an extra
    /// click. Mirrors the Spotify/Apple Music "queue up" UX.
    private func enqueueAndStartIfIdle(_ item: MusicQueueItem) {
        queue.append(item)
        if !isAnyPlayerActive() {
            _ = playNextInQueue()
        }
    }

    /// Build a queue item from a search-sheet result and route it
    /// into the shared enqueue-then-start flow. Keeps the .sheet
    /// onSelect callback short and consistent with the Open File /
    /// Sample buttons.
    private func enqueueSearchResult(_ result: MusicSearchResult) {
        let item: MusicQueueItem
        switch result.kind {
        case .appleMusic(let song):
            item = MusicQueueItem(
                title: result.title,
                artist: result.artist,
                duration: nil,
                source: .appleMusic(song))
        case .lrclib, .demo:
            // Pure-lyrics results have no audio source attached, so
            // they route through the sample-LRC path. We stash the
            // LRC text on the karaoke store right before play so the
            // overlay shows the correct lines.
            item = MusicQueueItem(
                title: result.title,
                artist: result.artist,
                duration: nil,
                source: .sampleLRC)
            // Save the parsed track on the karaoke store immediately
            // so play(item:) below can reuse it. (sampleLRC path will
            // overwrite it with the demo track otherwise.)
            karaoke.track = LRCParser.parse(result.lrc)
            currentTrackTitle = result.title
        }
        enqueueAndStartIfIdle(item)
    }

    /// True iff a player owns the timeline right now.
    private func isAnyPlayerActive() -> Bool {
        if musicKit.isActive { return true }
        if audioFile.isPlaying { return true }
        return false
    }

    /// Pop the next queued item and route it to the right player.
    /// Returns true if something started, false at end-of-queue so
    /// callers can mark the transport idle.
    @discardableResult
    private func playNextInQueue() -> Bool {
        guard let next = queue.advance() else { return false }
        play(item: next)
        return true
    }

    /// Central per-item dispatcher. Stops whichever player isn't
    /// going to own this track, then kicks the one that is. Mirrors
    /// the source-switching logic the Search sheet used to do inline.
    private func play(item: MusicQueueItem) {
        currentTrackTitle = item.artist.map { "\(item.title) — \($0)" } ?? item.title
        karaokeLastTick = CFAbsoluteTimeGetCurrent()
        switch item.source {
        case .localFile(let url):
            musicKit.stop()
            do {
                try audioFile.load(url: url)
                audio.switchSource(.audioFile)
                if !audio.isRunning { audio.start() }
                karaokeEnabled = true
                karaokePlaying = true
                audioFile.play()
                if karaoke.track == nil { karaoke.loadSample() }
            } catch {
                currentTrackTitle = "⚠︎ \(error.localizedDescription)"
            }

        case .appleMusic(let song):
            audioFile.stop()
            if audio.source != .microphone { audio.switchSource(.microphone) }
            if !audio.isRunning { audio.start() }
            karaokeEnabled = true
            karaokePlaying = true
            karaoke.clear()
            Task { @MainActor in
                await musicKit.play(song: song)
                let hits = (try? await LRCLibClient.search(
                    track: item.title,
                    artist: item.artist ?? "")) ?? []
                if let synced = hits.first(where: { $0.syncedLyrics?.isEmpty == false })?.syncedLyrics {
                    karaoke.track = LRCParser.parse(synced)
                }
            }

        case .sampleLRC:
            musicKit.stop()
            audioFile.stop()
            // If `enqueueSearchResult` already pre-loaded an LRC for
            // this row, keep it; otherwise fall back to the bundled
            // demo so the karaoke overlay still has something to
            // animate.
            if karaoke.track == nil { karaoke.loadSample() }
            karaoke.currentTime = 0
            karaokeEnabled = true
            karaokePlaying = true
        }
    }

    // MARK: - Queue section UI

    /// Scrollable "Up Next" list rendered inside the music menu.
    /// Each row shows source icon + title + duration; the current
    /// row is highlighted. Per-row controls: up / down / remove.
    /// Whole-row tap jumps the cursor and plays that item now.
    @ViewBuilder
    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.append")
                    .foregroundStyle(.secondary)
                Text("UP NEXT")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                if !queue.items.isEmpty {
                    Text("· \(queue.items.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !queue.items.isEmpty {
                    Button(role: .destructive) {
                        queue.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            if queue.items.isEmpty {
                Text("Queue is empty. Add tracks from Search, Open File, or Sample.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(queue.items.enumerated()), id: \.element.id) { idx, item in
                            queueRow(index: idx, item: item)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    @ViewBuilder
    private func queueRow(index: Int, item: MusicQueueItem) -> some View {
        let isCurrent = (queue.currentIndex == index)
        HStack(spacing: 8) {
            Image(systemName: isCurrent
                  ? (karaokePlaying ? "speaker.wave.2.fill" : "speaker.fill")
                  : item.sourceIcon)
                .foregroundStyle(isCurrent ? Color.green : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let a = item.artist, !a.isEmpty {
                    Text(a)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let d = item.duration, d > 0 {
                Text(timecode(d))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            // Reorder + remove controls. Compact so a row fits in
            // ~26pt without truncating the title.
            Button {
                queue.moveUp(index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(index == 0)

            Button {
                queue.moveDown(index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(index == queue.items.count - 1)

            Button {
                queue.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent
                      ? Color.green.opacity(0.12)
                      : Color.white.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let it = queue.jump(to: index) {
                play(item: it)
            }
        }
    }

    // MARK: - (legacy, retained for use in the music menu)

    @ViewBuilder
    private var karaokeRow_unused: some View {
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

    // MARK: - Background panel (top-right HUD card)

    /// Compact card exposing the background scrim (colour + opacity)
    /// and the toggleable ASCII counter-depth environment. Mirrors
    /// the `.white.opacity(0.04)` card chrome used elsewhere in the
    /// HUD so the panels feel like one set.
    @ViewBuilder
    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("BACKGROUND")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                // Native colour picker — supportsOpacity:false because
                // we expose opacity on a dedicated slider so the user
                // can see the numeric value.
                ColorPicker("color",
                            selection: $bgColor,
                            supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 28, height: 18)
                flashSlider(label: "opacity",
                            value: $bgOpacity,
                            range: 0...1,
                            fmt: "%.2f")
                Spacer()
            }

            Divider().opacity(0.25)

            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text("ASCII DEPTH")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $asciiDepthEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .help("Counter-depth ASCII environment. Hollow centre, rushing edges — feels inside-out.")
            }

            if asciiDepthEnabled {
                HStack(spacing: 14) {
                    flashSlider(label: "hue",
                                value: $asciiDepthHue,
                                range: 0...1,
                                fmt: "%.2f")
                    flashSlider(label: "sat",
                                value: $asciiDepthSaturation,
                                range: 0...1,
                                fmt: "%.2f")
                    Circle()
                        .fill(Color(hue: asciiDepthHue,
                                    saturation: asciiDepthSaturation,
                                    brightness: 1.0))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                }
                HStack(spacing: 14) {
                    flashSlider(label: "bright",
                                value: $asciiDepthBrightness,
                                range: 0...1,
                                fmt: "%.2f")
                    flashSlider(label: "density",
                                value: $asciiDepthDensity,
                                range: 0...1,
                                fmt: "%.2f")
                    flashSlider(label: "collapse",
                                value: $asciiDepthCollapse,
                                range: 0...1,
                                fmt: "%.2f")
                }
                HStack(spacing: 14) {
                    flashSlider(label: "audio",
                                value: $asciiDepthReactivity,
                                range: 0...1,
                                fmt: "%.2f")
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
        .foregroundStyle(.white)
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
        }
        .frame(maxWidth: .infinity)
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
    /// Namespaces each joint id with its personIndex so multiple
    /// people in frame each get an independent set of tracked blobs
    /// rather than fighting over the same `"left_wrist"` slot.
    private func updateBlobs() {
        guard blobsEnabled, let f = vision.latestFrame else { return }
        let samples: [(id: String, uv: SIMD2<Float>)] = f.joints
            .filter { $0.confidence >= 0.4 }
            .map { j in
                (id: "p\(j.personIndex)/\(j.id)",
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
        }
        .frame(maxWidth: .infinity)
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
