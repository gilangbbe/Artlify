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

| Item                                                                                  | Status      | Depends on | Effort |
| ------------------------------------------------------------------------------------- | ----------- | ---------- | ------ |
| Confirm `ml-stable-diffusion` Swift package minimum macOS version                     | not started | —          | 0.25 ed |
| Verify Continuity Camera works headlessly (no user gesture each launch)               | not started | M0         | 0.5 ed |
| Benchmark SD Turbo on M5 base: 512×512, fp16, 2 steps → measure FPS, latency, RAM     | not started | M1         | 1 ed   |
| Confirm zero-copy path from CoreML output (`MLShapedArray`) → `MTLTexture`            | not started | M1         | 0.5 ed |

### P1 — Required for v1

| Item                                                                                  | Status      | Depends on | Effort |
| ------------------------------------------------------------------------------------- | ----------- | ---------- | ------ |
| `CaptureKit` module: AVCaptureSession wrapper, `AsyncStream<CVPixelBuffer>`           | done        | M0         | —      |
| `RenderKit` module: MTKView, texture pool, basic blit pipeline                        | done        | M0         | —      |
| `VisionKit` module: person seg @ 30 Hz + pose @ 15 Hz, EMA mask smoothing             | not started | M2         | 2 ed   |
| `DiffusionKit` module: model load, img2img call, error handling, fp16 path            | not started | M1         | 3 ed   |
| FrameRouter actor (latest-frame-wins, drop-stale)                                     | done (folded into `AsyncStream.bufferingNewest(1)` in CaptureKit) | M0 | — |
| Temporal blend shader (lerp between two AI textures by timestamp)                     | not started | M3         | 1 ed   |
| Silhouette composite shader (camera mask over AI texture)                             | not started | M3         | 0.5 ed |
| `PromptKit`: rule-based modifier mapping + denoising-strength controller              | not started | M4         | 1 ed   |
| SwiftUI shell: prompt input, presets, HUD, fullscreen                                 | not started | M4         | 2 ed   |
| First-launch model downloader with SHA256 verification + progress UI                  | not started | M5         | 1.5 ed |
| Diffusion-stall fallback (>2 s no output → camera + post-FX only)                     | not started | M5         | 0.5 ed |
| Continuity Camera reconnect handling                                                  | not started | M5         | 0.5 ed |
| FPS / latency / RAM HUD (DEBUG builds always; user-toggleable in release)             | not started | M3         | 0.5 ed |
| 30-minute thermal soak test + eco-mode tuning                                         | not started | M5         | 1 ed   |

### P2 — Should-have polish

| Item                                                                          | Status      | Depends on | Effort |
| ----------------------------------------------------------------------------- | ----------- | ---------- | ------ |
| Bloom + grain + palette post-FX shaders                                       | not started | M3         | 1 ed   |
| Pose-delta warp between diffusion frames (cheap optical-flow approximation)   | not started | M3         | 2 ed   |
| Style preset library (5–8 hand-tuned prompts)                                 | not started | M4         | 1 ed   |
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

| Item                                                          | Status      | Notes                                                  |
| ------------------------------------------------------------- | ----------- | ------------------------------------------------------ |
| Measure end-to-end Continuity Camera latency on real M5       | not started | Requires running the M0 app with an iPhone connected.  |

---

## Completed

| Item                                                                     | Date       |
| ------------------------------------------------------------------------ | ---------- |
| **M0 — Project skeleton + camera passthrough** (build green, 0 warnings)| 2026-05-11 |
| `CaptureKit/CameraCapture` — AVCaptureSession wrapper, AsyncStream<CVPixelBuffer>, latest-frame-wins, Continuity-Camera-preferred device picker | 2026-05-11 |
| `RenderKit/CameraMetalRenderer` + `Passthrough.metal` — MTKView delegate, CVMetalTextureCache, full-screen-triangle blit, FPS log | 2026-05-11 |
| `RenderKit/CameraMetalView` — NSViewRepresentable wrapper                | 2026-05-11 |
| `AppShell/CameraSession` + rewritten `ContentView` with status HUD       | 2026-05-11 |
| Camera entitlement + `NSCameraUsageDescription` Info.plist key           | 2026-05-11 |
| Constraint-driven rewrite of `ProjectDocument.md`                        | 2026-05-11 |
| Established `Journal.md` and `Roadmap.md`                                | 2026-05-11 |
| Locked v1 stack: Continuity Camera + Vision + SD Turbo + Metal           | 2026-05-11 |

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
