# Artlify — Tech Stack (universe-tune branch)

## Platform & Language

| Layer | Technology |
|---|---|
| Language | Swift 5.0 |
| Platform | macOS (deployment target 26.0) |
| UI Framework | SwiftUI + AppKit |
| Concurrency | Swift Concurrency (`async/await`, `actor`, `@MainActor`) + `@Observable` |
| Project format | Xcode `.xcodeproj` (single-target native Mac app) |

---

## Active Modules

### AppShell
Glue layer owned by `ContentView`. `CameraSession` (`@MainActor @Observable`) starts `CameraCapture`, streams `CVPixelBuffer` frames via `AsyncStream`, and feeds them to the Metal renderer. `VisionSession` runs Vision inference on a background actor and publishes pose + mask results.

### CaptureKit — `AVFoundation`
- `AVCaptureSession` delivers live camera frames as `CVPixelBuffer` via `AsyncStream`
- Supports Continuity Camera, hot-plugging, device enumeration

### VisionKit — `Vision`
- `VNGeneratePersonSegmentationRequest` — real-time person alpha matte (`.balanced` quality)
- `VNDetectHumanBodyPoseRequest` — body skeleton with per-joint confidence scores
- Both requests share one `VNImageRequestHandler.perform()` call per frame (CPU/ANE)
- Body joint UV coordinates feed directly into `TileEngine` hit detection

### RenderKit — `Metal` + `MetalKit`
Six pipeline states encoded into a single `MTLCommandBuffer` per frame:

| Pipeline | Shader | Purpose |
|---|---|---|
| `passthroughPipeline` | `Passthrough.metal` | Blit camera texture to drawable |
| `trailDecayPipeline` | `Trail.metal` | Ping-pong accumulator fade (motion trails) |
| `particleRenderPipeline` | `Particles.metal` | Draw 60k particle points additively |
| `negativeBoxesPipeline` | `NegativeBoxes.metal` | Inverted-camera flash windows at body joints |
| `asciiPipeline` | `Ascii.metal` | ASCII glyph overlay inside silhouette + audio shockwave ring |
| `compositePipeline` | `Composite.metal` | Camera + AI stylized blend (unused on this branch) |

Zero-copy camera→GPU path via `CVMetalTextureCache`.

### ParticleKit — Metal Compute
- 60,000 GPU-side particles simulated via `MTLComputePipelineState` (`update_particles` kernel)
- Curl-noise flow field drives the fluid swarm look
- Person segmentation mask is sampled in the compute shader as an attraction/repulsion field — moving your body pushes particles around
- Reads `AudioFrame` each frame: flow strength, glow intensity, and transient shockwave origin track the mic input
- Additive blending for glow accumulation; ping-pong trail accumulator for motion persistence

### AudioKit — `AVFoundation` + `Accelerate`
- `AVAudioEngine` taps the microphone at 1024-sample buffers
- `vDSP` FFT (N=1024, Hann window) runs off the audio render thread via `DispatchQueue`
- Publishes `AudioFrame`: broadband RMS level, low (≤200 Hz), mid (200–2 kHz), high (2–8 kHz), stereo pan, transient attack

### GameKit — `MusicKit` + `AVFoundation` + custom game loop

This is the focus of the `universe-tune` branch. Six files compose the game:

| File | Role |
|---|---|
| `TileSong.swift` | Data model: `NoteEvent` (beat, lane, duration), built-in songs (*Experience*, *Für Elise*), `AppleMusicHandle` factory |
| `TileEngine.swift` | `@Observable @MainActor` game loop: spawns tiles, advances positions at 60 Hz, detects body-joint hits, tracks score/combo |
| `NotePlayer.swift` | `AVAudioEngine` + `AVAudioUnitSampler` (GM Grand Piano via macOS system DLS soundfont) + hall reverb; fires notes on hit and ghost notes on miss |
| `AppleMusicBrowser.swift` | Full-screen `MusicKit` catalog search UI; generates deterministic tile patterns from song title+artist hash |
| `SongPickerView.swift` | Song selection sheet (built-in tracks + Apple Music entry point) |
| `UniverseTuneOverlay.swift` | SwiftUI `Canvas` overlay drawn at 60 Hz on top of the camera/particle layers; glowing lane-coloured tile rectangles |

**Tile physics:**
- Fall speed: 0.22 UV/s (screen crossing ≈ 5.4 s)
- Hit zone: y = 0.72 UV
- Hit detection: any confident Vision body joint inside a tile rect counts as a hit
- Miss: tile leading edge passes y = 1.04 UV

**Audio playback** (`NotePlayer`) is independent of `AudioReactor` — `AudioReactor` taps the *input* node (mic), `NotePlayer` drives the *output* chain only.

**Apple Music** songs generate tile patterns seeded from `title.hashValue + artistName.hashValue`, so the same song always produces the same layout. BPM defaults to 120 (MusicKit's public API does not expose tempo).

### Entitlements
```
com.apple.security.app-sandbox
com.apple.security.device.camera
com.apple.security.device.audio-input
com.apple.security.network.client          ← MusicKit catalog search
com.apple.security.files.user-selected.read-only
```

---

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────┐
│                    ArtlifyApp  (SwiftUI @main)                     │
│                          ContentView                               │
│    ZStack: camera → particles → blobs → game tiles → HUD          │
└──┬──────────┬──────────┬──────────┬──────────┬─────────────────────┘
   │          │          │          │          │
   ▼          ▼          ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────────────────┐
│Capture │ │AudioKit│ │Vision  │ │GameKit │ │    SongPickerView    │
│  Kit   │ │        │ │  Kit   │ │        │ │    AppleMusicBrowser │
│        │ │AVAudio │ │VNPerson│ │TileEng.│ │    (MusicKit)        │
│AVCapture│ │Engine  │ │Segment │ │NotePlay│ └──────────┬───────────┘
│Session │ │vDSP FFT│ │VNBody  │ │TileSong│            │
│AsyncStr│ │AudioFrm│ │ Pose   │ │Overlay │            │ AppleMusicHandle
└───┬────┘ └───┬────┘ └───┬────┘ └────┬───┘            │
    │          │          │           │                 │
    │          │          │           ◄─────────────────┘
    ▼          │          ▼           │
┌──────────────────────────────┐      │ body joints (UV)
│       CameraSession          │      │
│  (@MainActor @Observable)    │      │
└─────────────┬────────────────┘      │
              │                       │
    ┌─────────▼──────────┐            │
    │   ParticleField    │◄───────────┘
    │   (@Observable)    │
    │   60k GPU particles│◄── AudioFrame (level / bands / transient)
    │   curl-noise flow  │◄── person mask (attraction / repulsion)
    └─────────┬──────────┘
              │ encodeUpdate() / encodeRender()
              ▼
┌─────────────────────────────────────────────────────────┐
│           CameraMetalRenderer  (MTKViewDelegate)         │
│                                                         │
│  Per-frame MTLCommandBuffer:                            │
│                                                         │
│  [Compute]   update_particles   ──► particle buffer     │
│  [Render 1]  trail_decay_fragment  (ping-pong accum)    │
│  [Render 2]  particle_vertex/fragment  (additive glow)  │
│  [Render 3]  passthrough_fragment  (camera blit)        │
│  [Render 4]  negative_boxes_fragment  (body flashes)    │
│  [Render 5]  ascii_fragment  (glyph overlay + shock)    │
│                                                         │
│  CVMetalTextureCache  ──► zero-copy camera→GPU          │
└─────────────────────────────────────────────────────────┘
              │
              ▼  (MTKView drawable)
┌─────────────────────────────────────────────────────────┐
│              UniverseTuneOverlay  (SwiftUI Canvas)       │
│  drawn at 60 Hz on top — lane dividers + glowing tiles  │
└─────────────────────────────────────────────────────────┘
```

---

## Data Flow Per Frame

```
Camera frame (CVPixelBuffer, ~60 Hz)
  │
  ├──► CameraMetalRenderer.submit()   ─► GPU texture (zero-copy)
  │
  └──► VisionProcessor.process()       (actor, ~15 Hz)
         ├──► personMask (R8)  ─► renderer.submitMask()
         │                          └──► ParticleField repulsion
         │                          └──► ascii silhouette gate
         └──► joints (UV)      ─► ContentView
                                    ├──► TileEngine.tick(joints:)   ← hit detection
                                    └──► ParticleField.bodyCenter   ← shockwave origin

Microphone (AVAudioEngine tap, 1024 samples)
  └──► vDSP FFT ──► AudioFrame
                      ├──► ParticleField  (flow / glow / shockwave)
                      └──► ascii shockwave ring (CameraMetalRenderer)

TileEngine (60 Hz game timer)
  ├──► spawns LiveTile from TileSong.events at beat time
  ├──► advances tile positions by fallSpeed × dt
  ├──► checks joint UVs against tile rects  ─► hit / miss
  └──► NotePlayer.play(lane:) on hit  /  NotePlayer.playGhost(lane:) on miss
         └──► AVAudioUnitSampler (GM Piano, DLS soundfont)
               └──► AVAudioUnitReverb (LargeHall2)  ─► speakers

MusicKit (on demand)
  └──► AppleMusicBrowser search ──► AppleMusicHandle
         └──► TileSong.fromAppleMusic()  (deterministic tile pattern from title hash)
               └──► TileEngine.load(song:)
```
