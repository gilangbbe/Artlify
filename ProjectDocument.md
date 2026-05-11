# Artlify — Real-Time Generative Art From iPhone Camera (macOS)

> Status: Technical planning v1
> Target hardware: MacBook Pro M5 (base chip), 24 GB unified memory, 10‑core GPU
> Team profile: Small team, limited time, no ML training budget, no labeled datasets

---

## 1. Vision (Concrete)

Artlify turns a person standing in front of an iPhone camera into a continuously evolving piece of generative artwork, displayed on a Mac, with **no cloud dependency** and using only **pre-trained, off-the-shelf models** running locally on Apple Silicon.

The minimum experience that defines "done" for v1:

- iPhone is used as a webcam via **Continuity Camera** (no custom networking, no custom iOS app).
- macOS app captures frames at 30 FPS at 720p.
- Apple **Vision** framework detects the person silhouette and pose in real time.
- A **local image-to-image diffusion model** (SD Turbo via CoreML) restyles the person according to a chosen prompt.
- The stylized output is displayed full-screen with smooth temporal blending.
- Pose / motion / number of people modulate the prompt and post-processing in real time.

Anything beyond this (multi-style mixing, projection mapping, audio reactivity, ControlNet, etc.) is **explicitly out of scope for v1** and lives in [Roadmap.md](Roadmap.md).

---

## 2. Why These Constraints Drive Every Choice

We do **not** have:

- Labeled datasets, GPUs for training, or time for fine-tuning.
- Budget for cloud inference at interactive frame rates.
- A dedicated ML engineer.

Therefore the entire system is built around three rules:

1. **No training, ever.** Use only pre-trained models distributed by Apple, Stability AI, or Hugging Face under permissive licenses, converted to CoreML.
2. **Everything runs on-device.** No backend, no API keys, no network latency.
3. **Frame budget is sacred.** At 30 FPS we have ~33 ms per frame. Diffusion will not hit that on an M5 base chip — so we accept **3–6 generated FPS** for the AI layer and use the camera feed + GPU effects to maintain a perceived 60 FPS.

This is the single most important architectural insight in the document: **the diffusion model is a slow async producer; the renderer is a fast consumer that interpolates.**

---

## 3. Realistic Performance Budget (M5 base, 24 GB)

| Stage                           | Resolution | Target latency | Frequency | Notes                                                             |
| ------------------------------- | ---------- | -------------- | --------- | ----------------------------------------------------------------- |
| Camera capture                  | 1280×720   | <5 ms          | 30 FPS    | AVFoundation, Continuity Camera                                   |
| Vision: person seg              | 512×512    | 8–15 ms        | 30 FPS    | `VNGeneratePersonSegmentationRequest` (.balanced)                 |
| Vision: pose                    | 512×512    | 5–10 ms        | 15 FPS    | `VNDetectHumanBodyPoseRequest`, half-rate is fine                 |
| Diffusion (img2img, 1–4 steps)  | 512×512    | 150–400 ms     | 3–6 FPS   | SD Turbo via CoreML, ANE+GPU                                      |
| Renderer + temporal blend       | 1920×1080  | <8 ms          | 60 FPS    | Metal, blends latest AI frame with live camera + effects          |

**Implication:** The AI image is a *slowly-updating texture*; the camera silhouette and Metal effects provide motion fluidity. This is the same pattern used by StreamDiffusion and TouchDesigner pipelines — the only realistic path on this hardware.

All numbers above are **assumptions to be verified in milestone M1**. They are not guarantees; the design tolerates a 2× miss on diffusion latency without breaking the experience (we just blend longer).

---

## 4. System Architecture

```
┌────────────────┐  Continuity Camera   ┌──────────────────────────────┐
│ iPhone Camera  │─────────────────────▶│ AVCaptureSession (macOS)     │
└────────────────┘                      └──────────────┬───────────────┘
                                                       │ CVPixelBuffer (BGRA, 30 FPS)
                                                       ▼
                              ┌────────────────────────────────────────┐
                              │ FrameRouter (actor)                    │
                              │  - publishes latest frame              │
                              │  - drops stale frames (no queue build) │
                              └───┬────────────────┬───────────────────┘
                                  │                │
                                  ▼                ▼
                  ┌────────────────────┐   ┌────────────────────────────┐
                  │ VisionPipeline     │   │ DiffusionPipeline (async)  │
                  │  - person seg mask │   │  - img2img, 2–4 steps      │
                  │  - body pose (15Hz)│   │  - prompt + latent input   │
                  │  - person count    │   │  - 512×512 CoreML          │
                  └─────────┬──────────┘   └──────────────┬─────────────┘
                            │                             │ MTLTexture (latest stylized frame)
                            ▼                             ▼
                  ┌──────────────────────────────────────────────────┐
                  │ MetalRenderer (60 FPS)                           │
                  │  - composites: camera + mask + AI frame          │
                  │  - temporal blend (lerp between AI frames)       │
                  │  - post FX (bloom, grain, palette)               │
                  └──────────────────────┬───────────────────────────┘
                                         ▼
                                 ┌───────────────┐
                                 │ MTKView / FS  │
                                 └───────────────┘
```

Key invariants:

- **One latest-frame slot** between stages (no growing queues). Backpressure = drop, never buffer.
- **Stages communicate via Swift `actor`s and `AsyncStream`s.** No locks in hot paths; the renderer pulls the most recent texture each vsync.
- **Diffusion runs on its own task** and is skipped entirely if the previous one hasn't returned.

---

## 5. Module Breakdown

The codebase is organized into independent, testable Swift modules. Each is small enough that one engineer owns it end-to-end.

| Module               | Responsibility                                              | Key APIs                              |
| -------------------- | ----------------------------------------------------------- | ------------------------------------- |
| `CaptureKit`         | Wrap AVFoundation, expose `AsyncStream<CVPixelBuffer>`      | AVFoundation, Continuity Camera       |
| `VisionKit`          | Person segmentation + pose, throttled per-request           | Vision framework                      |
| `DiffusionKit`       | Load CoreML SD Turbo, run img2img, return MTLTexture        | CoreML, MPS, `ml-stable-diffusion`    |
| `RenderKit`          | Metal pipeline, shaders, temporal blend, post FX            | Metal, MetalKit                       |
| `PromptKit`          | Map detected features (pose, count, motion) → prompt + params | Pure Swift, no deps                 |
| `AppShell` (SwiftUI) | UI: prompt entry, style picker, FPS HUD, fullscreen toggle  | SwiftUI                               |

Rule: **no module imports another module's internals.** They communicate via value types and `AsyncStream`. This keeps each piece replaceable (e.g., we can swap SD Turbo for a different model without touching the renderer).

---

## 6. Technology Choices (and Why)

### 6.1 iPhone → Mac transport: **Continuity Camera**

- **Why:** Zero code, zero networking. AVFoundation sees the iPhone as a normal `AVCaptureDevice`. Latency is ~80–120 ms, acceptable.
- **Rejected:** NDI, custom UDP/RTSP, WebRTC — all add weeks of work, debugging, and a custom iOS app. Out of budget.
- **Tradeoff:** Requires the user to be in the Apple ecosystem and the iPhone nearby. Acceptable for v1.

### 6.2 Person detection: **Apple Vision framework**

- **Why:** Free, on-device, ANE-accelerated, no model to ship, no licensing. `VNGeneratePersonSegmentationRequest` returns a clean alpha mask in <15 ms at `.balanced` quality.
- **Rejected:** YOLO / SAM / Segment Anything — heavier, larger binaries, no quality win for a single foreground person.
- **Tradeoff:** Multi-person identity tracking is mediocre; we accept this and only count people in v1.

### 6.3 Generative model: **SD Turbo via CoreML, img2img, 1–4 steps**

- **Why:**
  - **No training required** — pre-trained, permissively licensed (SAI Community / CreativeML Open RAIL-M).
  - **Designed for 1–4 step inference**, the only diffusion family that can hit sub-second latencies on a base M5.
  - Apple's [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion) Swift package gives us a tested CoreML conversion path and a Swift API.
  - img2img with low denoising strength (0.4–0.6) preserves the silhouette so the output tracks the person.
- **Rejected:**
  - **Full SDXL / Flux** — too slow (>5 s/frame) on base M5; blows the 24 GB budget once Vision + Metal are loaded.
  - **ControlNet** — roughly doubles memory and latency. Defer to v2.
  - **StreamDiffusion** — promising but Python/CUDA-first; porting to CoreML is a research project, not a sprint task.
  - **Cloud inference (Replicate / Fal)** — kills the offline goal, costs money per frame, adds 300–1500 ms RTT.
- **Tradeoff:** ~3–6 generated FPS. Mitigated by the temporal-blend renderer (Section 7).

### 6.4 Rendering: **Metal + MetalKit, custom MTKView**

- **Why:** Direct GPU access, zero-copy from CoreML output (`MLShapedArray` → `MTLTexture`), shader-based post FX is trivial.
- **Rejected:** SceneKit / RealityKit (overkill), SwiftUI Canvas (CPU-bound).
- **Tradeoff:** Shader code is verbose. Mitigated by keeping the pass count small (≤6).

### 6.5 UI: **SwiftUI**

Standard, fast to iterate, sufficient for prompt input + HUD + fullscreen toggle.

### 6.6 Concurrency: **Swift Concurrency (async/await, actors, AsyncStream)**

Built-in, no Combine sprawl, structured cancellation makes "drop stale frame" trivial.

### 6.7 Build & dependencies

- Single Xcode project, **SwiftPM only** for external deps.
- One external dependency: `apple/ml-stable-diffusion` (Swift package).
- Minimum macOS: **15.0** (required for the `ml-stable-diffusion` Swift API and Vision improvements). To be confirmed in M0.

---

## 7. The Temporal Blend Strategy (Critical)

Because diffusion produces ~5 FPS but we display 60 FPS, the renderer must hide the gap:

1. Renderer holds two textures: `aiPrev` and `aiNext` (latest two diffusion outputs).
2. Each vsync, it computes `t = clamp((now - aiNextTimestamp) / expectedInterval, 0, 1)` and lerps.
3. The live camera silhouette (from the Vision mask) is composited **on top** at 30 FPS, so the user sees their own motion immediately while the AI styling "catches up" softly.
4. Optional (v1.1): a shader-driven warp uses pose-joint deltas to distort `aiNext` between diffusion updates — a cheap optical-flow approximation.

This is the difference between "feels broken at 5 FPS" and "feels like a living painting."

---

## 8. Prompt & Behavior Mapping (`PromptKit`)

Inputs available per frame:

- `personCount: Int`
- `largestBoundingBoxArea: Float` (proxy for distance)
- `motionEnergy: Float` (mean abs pose-joint delta over the last N frames)
- `dominantPose: enum { standing, armsRaised, crouching, sitting, unknown }`

Mapping (v1, hand-crafted, no ML):

| Signal                       | Effect                                                  |
| ---------------------------- | ------------------------------------------------------- |
| `motionEnergy > 0.6`         | Append "dynamic, swirling, energetic brushstrokes"      |
| `motionEnergy < 0.1`         | Append "serene, still, soft light"                      |
| `personCount >= 2`           | Append "two figures intertwined"                        |
| `largestBoundingBoxArea`     | Maps to `denoisingStrength` (closer = more stylization) |
| `dominantPose == armsRaised` | Append "ascending, radiant"                             |

User-supplied base prompt is concatenated with these modifiers. **No LLM, no embeddings, no training.** Pure rule-based, fully debuggable.

---

## 9. Models We Will Ship

| Asset                              | Source                       | Size (CoreML, fp16) | Notes                                  |
| ---------------------------------- | ---------------------------- | ------------------- | -------------------------------------- |
| SD Turbo (UNet + VAE + text enc.)  | `apple/ml-stable-diffusion`  | ~1.7 GB             | Primary generator                      |
| SDXL Turbo (optional, v1.1)        | `apple/ml-stable-diffusion`  | ~6 GB               | Higher quality, slower; evaluate later |
| Vision person seg / pose           | Built into macOS             | 0                   | No ship cost                           |

Models are **downloaded on first launch** from Hugging Face into `~/Library/Application Support/Artlify/Models/` with a SHA256 check pinned in a `Models.lock` JSON, **not** bundled in the app. This keeps the binary small, makes model updates easy, and avoids licensing surprises in distribution.

---

## 10. Engineering Principles (Applied)

| Principle                   | How it shows up here                                                                      |
| --------------------------- | ----------------------------------------------------------------------------------------- |
| Simplicity                  | One process, no IPC, no server, no database.                                              |
| Maintainability             | 6 small modules, each <500 LOC target, no cross-imports.                                  |
| Small deployable increments | Milestones M0–M5 each produce a runnable app (see [Roadmap.md](Roadmap.md)).              |
| Low operational cost        | $0/month. No cloud, no telemetry.                                                         |
| Low hardware requirements   | Designed for base M5; degrades on M2/M3 by lowering resolution.                           |
| Fast iteration              | Hot-reload prompts via the text field; shaders editable without rebuild via watched `.metal` files in DEBUG. |
| Minimal dependencies        | Apple frameworks + `ml-stable-diffusion`. That's it.                                      |
| Modular architecture        | Each module behind a protocol; mocks for unit tests.                                      |
| Graceful degradation        | If diffusion stalls > 2 s, renderer shows camera + stylized post-FX only.                 |
| Offline resilience          | After first model download, fully offline.                                                |

---

## 11. Risks & Mitigations

| Risk                                                         | Likelihood | Mitigation                                                                                  |
| ------------------------------------------------------------ | ---------- | ------------------------------------------------------------------------------------------- |
| Diffusion latency higher than expected on M5 base            | High       | Fall back to 384×384, fewer steps, or LCM-distilled model. Always keep fallback FX path.    |
| Continuity Camera disconnects mid-session                    | Medium     | Detect via AVCaptureSession notifications, show reconnection UI, keep last frame on screen. |
| Memory pressure (UNet + Vision + Metal textures)             | Medium     | Use fp16 everywhere, recycle texture pool, never load SDXL while SD Turbo is active.        |
| Vision mask flicker frame-to-frame                           | Medium     | Temporal smoothing (EMA) on the alpha mask in a Metal shader.                               |
| Model licensing changes                                      | Low        | Pin model commits in `Models.lock` with SHA256.                                             |
| Thermal throttling on long sessions                          | Medium     | Expose a "performance vs. quality" slider; cap diffusion to 3 FPS in eco mode.              |

---

## 12. Out of Scope for v1 (Tracked in Roadmap)

- ControlNet / pose-conditioned generation
- Multiple simultaneous styles / style mixing
- Audio reactivity
- Projection mapping / multi-display
- Recording / export pipeline
- iOS companion app with custom streaming
- Fine-tuning or LoRA training
- Multi-person identity tracking

---

## 13. Open Questions / Assumptions

Stated explicitly so we can revisit:

1. **Assumption:** SD Turbo at 512×512, 2 steps, fp16, achieves ≥3 FPS on M5 base. *To be benchmarked in M1.*
2. **Assumption:** Continuity Camera latency is acceptable (<150 ms end-to-end). *To be measured in M0.*
3. **Assumption:** A single foreground person is the dominant use case; multi-person is a v2 concern.
4. **Open:** Do we want a "kiosk mode" (auto-fullscreen, no UI) for installations? Defer until after v1 demo.
5. **Open:** Minimum macOS version — likely 15.0; confirm against `ml-stable-diffusion` requirements in M0.

---

## 14. Companion Documents

- [Journal.md](Journal.md) — chronological engineering log; every non-trivial decision goes here.
- [Roadmap.md](Roadmap.md) — milestones, backlog, status. Updated weekly.
