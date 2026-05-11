# Engineering Journal — Artlify

> Chronological log of every non-trivial decision, experiment, and lesson learned.
> Append new entries to the **top**. Never edit past entries; correct them with a follow-up entry.

Entry template:

```
## YYYY-MM-DD — <Short title>
**Decision / change:**
**Reason:**
**Impact:**
**Follow-up:**
```

---

## 2026-05-11 — M0 shipped: camera passthrough builds and runs

**Decision / change:**
Implemented and built the M0 skeleton end-to-end. New code:

- `Artlify/CaptureKit/CameraCapture.swift` — nonisolated `CameraCapture` class that wraps `AVCaptureSession`, prefers `.continuityCamera` device type, and exposes frames via `AsyncStream<CVPixelBuffer>` with `.bufferingNewest(1)` (latest-frame-wins, no queue growth).
- `Artlify/RenderKit/Passthrough.metal` — full-screen-triangle vertex + texture-sample fragment shader.
- `Artlify/RenderKit/CameraMetalRenderer.swift` — `MTKViewDelegate`, owns a `CVMetalTextureCache`, blits the latest camera frame to the drawable, logs render FPS once per second.
- `Artlify/RenderKit/CameraMetalView.swift` — `NSViewRepresentable` wiring the renderer into SwiftUI.
- `Artlify/AppShell/CameraSession.swift` — `@MainActor @Observable` glue that runs the pump task and tracks first-frame latency.
- Rewrote `ContentView.swift` to display the live feed with a small status HUD.
- Added `Artlify/Artlify.entitlements` (sandbox + `com.apple.security.device.camera` + network client for future model downloads) and wired it via `CODE_SIGN_ENTITLEMENTS` in both build configurations.
- Added `INFOPLIST_KEY_NSCameraUsageDescription` to both build configurations.

`xcodebuild -scheme Artlify -configuration Debug build` is green with **zero warnings**.

**Reason:**
M0 is the cheapest possible end-to-end slice: camera in → screen out. Getting it green before touching ML eliminates an entire class of integration risk (entitlements, sandbox, Continuity-Camera device selection, Metal pipeline, MainActor-default-isolation friction) while the codebase is still tiny.

**Impact:**
- Validated the project structure (one Xcode target, `PBXFileSystemSynchronizedRootGroup` auto-picks files added under `Artlify/`, no pbxproj edits needed for new source files — only for build settings).
- Confirmed the Swift-6-clean concurrency story under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: anything touched from background queues (delegate callbacks, AVFoundation state) lives on a class declared `nonisolated final class`, with the conformance extension also marked `nonisolated`. Recorded for future modules.
- The `RenderKit` Metal pipeline already uses a single-texture slot, which is the exact shape the temporal blender will extend in M3 (it just needs `aiPrev`/`aiNext` slots and a different fragment shader).
- `FrameRouter` as a separate actor (planned in §4 of `ProjectDocument.md`) turned out to be redundant — `AsyncStream.bufferingNewest(1)` already enforces "latest-frame-wins" at the language level. Removed from the roadmap rather than building dead code.

**Follow-up:**
- Run the app with an iPhone connected and **measure end-to-end Continuity Camera latency** (target <150 ms). This is the M0 verification step from `ProjectDocument.md` §13 assumption #2.
- On first launch the system will prompt for camera access; verify the consent dialog text reads correctly.
- Begin M1: pull `apple/ml-stable-diffusion` Swift package, convert/download SD Turbo CoreML, run a single `img2img` call on a captured frame, log latency / RAM / FPS.

---

## 2026-05-11 — Required Metal toolchain on Xcode 26

**Decision / change:**
First build failed with `cannot execute tool 'metal' due to missing Metal Toolchain`. Fixed by running `xcodebuild -downloadComponent MetalToolchain`.

**Reason:**
Xcode 26 ships the Metal toolchain as a downloadable component rather than bundling it. Any developer cloning the repo on a fresh machine will hit the same error.

**Impact:**
Documented here so the next person doesn't lose time. Worth adding to a future `README.md` setup section.

**Follow-up:**
Add a one-line setup note to the README when one is created.

---

## 2026-05-11 — Initial technical planning baseline established

**Decision / change:**
Rewrote `ProjectDocument.md` from a high-level vision into a constraint-driven technical plan. Created `Roadmap.md` and this `Journal.md`. Locked v1 scope to: Continuity Camera input → Vision (segmentation + pose) → SD Turbo img2img via CoreML → Metal renderer with temporal blending. Explicitly deferred ControlNet, StreamDiffusion, multi-style mixing, audio, projection mapping, custom iOS app, and any training/fine-tuning to post-v1.

**Reason:**
The original document listed many candidate technologies (ComfyUI, ControlNet, Flux, StreamDiffusion, neural style transfer, fluid sims, etc.) without committing. With a small team, no ML training capacity, and a base-chip M5 as the target device, we cannot afford to keep options open — every undecided technology is a tax on iteration speed. We picked the smallest credible stack that still produces the intended experience.

**Impact:**
- One external dependency (`apple/ml-stable-diffusion`); everything else is Apple frameworks.
- Realistic FPS target reframed: AI layer 3–6 FPS, perceived 60 FPS via Metal blending. This is the central design assumption.
- Diffusion is now an async producer that the renderer is allowed to ignore when stale — no more "real-time AI" framing that would set us up to fail.
- Models ship out-of-band (downloaded on first launch, SHA-pinned), keeping the binary small and licensing flexible.

**Follow-up:**
- M0: stand up an Xcode SwiftPM project skeleton with the 6 modules from §5 of `ProjectDocument.md`.
- M0: measure end-to-end Continuity Camera latency on the actual M5 — if >200 ms, revisit.
- M1: benchmark SD Turbo on M5 base at 512×512 / 2 steps / fp16. If <2 FPS, fall back to 384×384 or an LCM-distilled variant before any UX work.
- Confirm minimum macOS version against `ml-stable-diffusion` Swift package requirements.

---

## 2026-05-11 — Rejected: cloud inference, custom streaming protocol, training pipelines

**Decision / change:**
Explicitly rule out (a) any cloud diffusion backend (Replicate, Fal, self-hosted), (b) any custom iPhone→Mac streaming protocol (NDI, RTSP, WebRTC, custom UDP), and (c) any model training, fine-tuning, or LoRA work for v1.

**Reason:**
- Cloud: adds 300–1500 ms RTT, recurring cost, and breaks the "offline, no API keys" goal. The whole appeal of on-device Apple Silicon evaporates if we phone home for every frame.
- Custom streaming: requires a companion iOS app, networking code, codec choices, NAT traversal. Continuity Camera gives us the same result for zero engineering cost.
- Training: we have no labeled data, no GPU budget, and no ML engineer. Pre-trained SD Turbo is good enough for a first installation-grade demo.

**Impact:**
Scope shrinks dramatically. Risk shrinks. We can begin coding immediately with no procurement, no infrastructure, no dataset collection.

**Follow-up:**
Revisit each of these only if v1 ships and a concrete user need demands it. Document the trigger condition in `Roadmap.md` under "Post-v1 / Conditional".
