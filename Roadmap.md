# Roadmap — Artlify

> Living document. Update at least weekly. Each item lists **Priority** (P0=blocker, P1=must, P2=should, P3=nice), **Status**, **Dependencies**, and **Estimated effort** in engineer-days (ed). Effort is a coarse t-shirt-sized estimate, not a deadline.

---

## Milestones (v1)

Each milestone produces a **runnable, demoable build**. We do not start the next until the previous is green.

| ID | Milestone                                  | Definition of done                                                                                  | Depends on |
| -- | ------------------------------------------ | --------------------------------------------------------------------------------------------------- | ---------- |
| M0 | Project skeleton + camera passthrough      | Xcode project with 6 module folders. App opens iPhone via Continuity Camera, displays raw feed in an MTKView at 30 FPS. End-to-end camera latency measured and logged. | —          |
| M1 | Diffusion benchmark + first stylized still | SD Turbo CoreML model loads, runs img2img on a single captured frame, displays result. FPS, latency, peak RAM logged. | M0         |
| M2 | Vision integration                         | Person segmentation mask + body pose overlay rendered live at 30 FPS. Person count surfaced.        | M0         |
| M3 | Live diffusion loop + temporal blend       | Diffusion runs continuously off the latest frame. Renderer blends latest two AI outputs at 60 FPS. Camera silhouette composited on top. Drop-stale-frame policy verified under load. | M1, M2     |
| M4 | PromptKit + UI                             | SwiftUI panel: prompt text field, style preset picker, eco/quality toggle, FPS HUD, fullscreen toggle. Pose/motion modulate prompt per §8 of `ProjectDocument.md`. | M3         |
| M5 | Hardening + demo polish                    | Reconnection handling, graceful diffusion-stall fallback, Models.lock + first-launch download UI, 30-minute thermal soak test passes. Ready to demo. | M4         |

---

## Backlog

### P0 — Blockers / unknowns to resolve before committing further

| Item                                                                                  | Status        | Depends on | Effort |
| ------------------------------------------------------------------------------------- | ------------- | ---------- | ------ |
| Confirm `ml-stable-diffusion` Swift package minimum macOS version                     | resolved (1.1.1, macOS 13.1+) | — | — |
| Verify Continuity Camera works headlessly (no user gesture each launch)               | resolved (notification-driven auto-switch + manual Reconnect button) | M0 | — |
| Convert SD Turbo to CoreML and place it in `~/Library/Application Support/Artlify/Models/sd-turbo/` | resolved (user did the conversion, model loads) | M1 code | — |
| Benchmark SD Turbo on M5 base: 512×512, fp16, 2 steps → measure FPS, latency, RAM     | **resolved — 512/ANE = 997 ms, 384/ANE = 660 ms (default in M4); below the ≥3 FPS target** (see ProjectDocument §13 #1) | M1 | — |
| Confirm zero-copy path from CoreML output (`MLShapedArray`) → `MTLTexture`            | not started   | M3         | 0.5 ed |

### P1 — Required for v1

| Item                                                                                  | Status      | Depends on | Effort |
| ------------------------------------------------------------------------------------- | ----------- | ---------- | ------ |
| **Diffusion-perf A/Bs given measured 1 FPS** — try 384×384, `.cpuAndGPU`, split UNet/VAE compute units | done — 384/ANE chosen as default (660 ms vs 512/ANE's 997 ms); pickers stay in HUD for manual override | M3         | —      |
| `CaptureKit` module: AVCaptureSession wrapper, `AsyncStream<CVPixelBuffer>`           | done        | M0         | —      |
| `RenderKit` module: MTKView, texture pool, basic blit pipeline                        | done        | M0         | —      |
| `VisionKit` module: person seg @ 30 Hz + pose @ 15 Hz, EMA mask smoothing             | done (`.balanced` seg + body pose at 15 Hz cap, runs in single VNImageRequestHandler) | M2         | —      |
| `DiffusionKit` module: model load, img2img call, error handling, fp16 path            | done        | M1         | —      |
| FrameRouter actor (latest-frame-wins, drop-stale)                                     | done (folded into `AsyncStream.bufferingNewest(1)` in CaptureKit) | M0 | — |
| Temporal blend shader (lerp between two AI textures by timestamp)                     | done (composite_fragment, EMA-tuned cycle length) | M3 | — |
| Silhouette composite shader (camera mask over AI texture)                             | done (folded into composite_fragment, mask_enabled uniform) | M3 | — |
| `PromptKit`: rule-based modifier mapping + denoising-strength controller              | done (StylePreset library + PromptComposer with pose + motion modifiers) | M4 | — |
| SwiftUI shell: prompt input, presets, HUD, fullscreen                                 | done (preset chips, extra-prompt field, fullscreen button, effective-prompt readout, modifier toggles) | M4 | — |
| First-launch model downloader with SHA256 verification + progress UI                  | not started | M5         | 1.5 ed |
| Diffusion-stall fallback (>2 s no output → camera + post-FX only)                     | not started | M5         | 0.5 ed |
| Continuity Camera reconnect handling                                                  | done        | M5         | —      |
| FPS / latency / RAM HUD (DEBUG builds always; user-toggleable in release)             | partial (per-subsystem ms/Hz lines in HUD; no RAM yet) | M3 | 0.25 ed |
| 30-minute thermal soak test + eco-mode tuning                                         | not started | M5         | 1 ed   |

### P2 — Should-have polish

| Item                                                                          | Status      | Depends on | Effort |
| ----------------------------------------------------------------------------- | ----------- | ---------- | ------ |
| Bloom + grain + palette post-FX shaders                                       | not started | M3         | 1 ed   |
| Pose-delta warp between diffusion frames (cheap optical-flow approximation)   | not started | M3         | 2 ed   |
| Style preset library (5–8 hand-tuned prompts)                                 | done (8 presets in `PromptKit/StylePreset.swift`) | M4 | — |
| Hot-reload of `.metal` shader files in DEBUG                                  | not started | M0         | 0.5 ed |
| Unit tests for `PromptKit` mapping rules                                      | not started | M4         | 0.5 ed |
| Mock implementations of each module behind protocols (for offline UI dev)    | not started | M0         | 1 ed   |

### P3 — Nice-to-have

| Item                                                       | Status      |
| ---------------------------------------------------------- | ----------- |
| MetalFX upscaling pass (M5 supports it)                    | not started |
| Per-style LUT color grading                                | not started |
| Save current frame to disk (PNG)                           | not started |
| Session video recording (ScreenCaptureKit)                 | not started |

---

## In Progress

| Item                                                                            | Status        | Notes                                                                              |
| ------------------------------------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------- |
| **M5 — Hardening + demo polish** | not started, unblocked by M4 ship | First-launch model downloader, diffusion-stall fade-out, 30-min thermal soak, minimal-HUD demo mode. |

---

## Completed

| Item                                                                                       | Date       |
| ------------------------------------------------------------------------------------------ | ---------- |
| Bugfix — presets/prompts had no visible effect because `strength × stepCount = 0.55 × 2 ≈ 1` effective denoising step. Bumped defaults to `strength=0.78, steps=4` and rebalanced every preset's `suggestedStrength` to 0.75–0.82. Trades ~660 ms/pass for ~1.2 s/pass; prompt now actually steers the output. | 2026-05-12 |
| Mask mode tri-state — `Composite.metal` + `CameraMetalRenderer.MaskMode { full, person, background }` replacing the boolean `mask_enabled`. Default flipped to `.background` so prompts like "starry night" repaint the environment while the person stays as live camera. HUD checkbox replaced with 3-segment Picker. | 2026-05-12 |
| Bugfix — `DiffusionBenchmark.init()` was hardcoded to the 512 model bundle while `variant` defaulted to 384, so the first live pass exploded with `Encoder.Error 0`. Init now uses literal defaults that match the property declarations. | 2026-05-11 |
| **M4 — PromptKit + UI polish** — `StylePreset` library (8 presets, each with suggestedSteps + suggestedStrength), `PromptComposer` with deterministic pose modifier (3 rules) + motion modifier (EMA-smoothed centroid speed → 3 buckets), wired through `DiffusionBenchmark.effectivePrompt`, preset-chip picker, extra-prompt field, on-screen effective-prompt readout with hint chips, modifier toggles, fullscreen button. Build green, 0 warnings. | 2026-05-11 |
| **Diffusion-perf A/B winner picked** — 384×384 + CPU+ANE = ~660 ms / pass (~1.5 Hz) vs 512/ANE's 997 ms. Set as default in `DiffusionBenchmark.variant`. | 2026-05-11 |
| **M3.5 — Diffusion-perf A/B knobs in UI** — `ComputeUnitChoice` + `ModelVariant` enums, mutable pipeline with explicit rebuild on change, `LiveDiffusionDriver` reads settings live so no restart needed, segmented pickers in HUD | 2026-05-11 |
| **M3 — Live diffusion loop + temporal blend + person composite** — `Composite.metal`, extended renderer (aiPrev/aiNext/mask slots, EMA-tuned blend cycle), `LiveDiffusionDriver` continuous loop, Live toggle + style slider + mask checkbox in HUD, stall detection | 2026-05-11 |
| **M2 verified on hardware** — Vision pass measured at ~32 ms (~31 Hz capable; throttled at 15 Hz to leave budget for diffusion) | 2026-05-11 |
| **M2 — VisionKit shipped** — `VisionFrame`, `VisionProcessor` actor (`.balanced` seg + body pose), `VisionSession` polling driver @ 15 Hz, `PoseOverlay` SwiftUI canvas with skeleton + dots, HUD toggle | 2026-05-11 |
| **M1 verified on hardware** — SD Turbo img2img runs end-to-end, 997 ms / pass measured (~1 FPS, below the ≥3 FPS prediction). ProjectDocument §13 #1 updated with the real number. | 2026-05-11 |
| **M1 scaffold** — `DiffusionKit` actor (img2img, CFG=0, dpm-solver, reduceMemory), benchmark UI, model-folder reveal | 2026-05-11 |
| M1 first-run bugfix — `PixelBufferToCGImage` now produces guaranteed-exact 512×512 output via fixed-size `CGContext`, avoiding `Encoder.Error.sampleInputShapeNotCorrect` | 2026-05-11 |
| Added `apple/ml-stable-diffusion` SwiftPM dependency (1.1.1) via direct pbxproj edit       | 2026-05-11 |
| Continuity Camera reconnect bug fix — device-connected/disconnected notifications, auto-switch to iPhone, manual Reconnect + device picker in HUD | 2026-05-11 |
| **M0 verified on hardware** — Continuity Camera end-to-end latency <150 ms (target met) | 2026-05-11 |
| **M0 — Project skeleton + camera passthrough** (build green, 0 warnings)                  | 2026-05-11 |
| `CaptureKit/CameraCapture` — AVCaptureSession wrapper, AsyncStream<CVPixelBuffer>, latest-frame-wins, Continuity-Camera-preferred device picker | 2026-05-11 |
| `RenderKit/CameraMetalRenderer` + `Passthrough.metal` — MTKView delegate, CVMetalTextureCache, full-screen-triangle blit, FPS log | 2026-05-11 |
| `RenderKit/CameraMetalView` — NSViewRepresentable wrapper                                  | 2026-05-11 |
| `AppShell/CameraSession` + rewritten `ContentView` with status HUD                         | 2026-05-11 |
| Camera entitlement + `NSCameraUsageDescription` Info.plist key                             | 2026-05-11 |
| Constraint-driven rewrite of `ProjectDocument.md`                                          | 2026-05-11 |
| Established `Journal.md` and `Roadmap.md`                                                  | 2026-05-11 |
| Locked v1 stack: Continuity Camera + Vision + SD Turbo + Metal                             | 2026-05-11 |

---

## Blocked

_None yet._ Use this section for items waiting on an external decision, hardware delivery, license clarification, etc. Each entry must record: **what** is blocked, **on what** it's blocked, **since when**, and **the unblock criterion**.

---

## Upcoming Milestones

Next 4 weeks (rough order, not committed dates):

1. **M0 — Project skeleton + camera passthrough.** Goal: prove the boring path works end-to-end before touching ML.
2. **M1 — Diffusion benchmark.** Goal: convert the central performance assumption into a measured number. **This is the highest-risk milestone.** If it fails, we change the model, the resolution, or the strategy *before* writing more code.
3. **M2 — Vision integration.** Goal: parallel track to M1; the Vision pipeline is well-understood and low-risk.
4. **M3 — Live loop + temporal blend.** Goal: the first build that actually feels like Artlify.

---

## Post-v1 / Conditional

Items deliberately out of scope for v1. Each lists the **trigger condition** that would justify revisiting.

| Item                                       | Trigger to reconsider                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------ |
| ControlNet (pose-conditioned generation)   | v1 ships and users report the silhouette tracking isn't tight enough.          |
| StreamDiffusion-style pipeline             | A maintained Swift/CoreML port appears, or we hire ML capacity.                |
| Cloud diffusion fallback                   | We need to support sub-M-series Macs.                                          |
| Custom iOS streaming app                   | We need to support non-Apple-ecosystem cameras or longer-distance setups.      |
| Multi-person identity tracking             | A specific installation requires per-person prompts.                           |
| Audio reactivity                           | Concrete artist/installation request with a defined audio source.              |
| Projection mapping / multi-display         | Concrete venue requirement.                                                    |
| Recording / export pipeline                | Users ask for it more than once.                                               |
| LoRA / fine-tuning                         | We acquire a labeled dataset and a training machine.                           |

---

## Update protocol

- When you start an item, move it to **In Progress** and set status.
- When you finish, move it to **Completed** with a date and add a `Journal.md` entry if the work changed any decision in `ProjectDocument.md`.
- When blocked, move to **Blocked** with all four required fields filled in.
- Re-estimate effort if reality diverges by >2×; note the divergence in `Journal.md`.
