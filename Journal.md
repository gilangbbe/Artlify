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

## 2026-05-11 — M0 verified on hardware: Continuity Camera <150 ms

**Decision / change:**
Ran the M0 build on the target M5 with an iPhone connected via cable. End-to-end latency from physical motion to on-screen draw measured **<150 ms**, well within the assumption in `ProjectDocument.md` §13 #2.

Discovered a bug: on a second build/launch, the iPhone is not picked up automatically. Continuity Camera devices are enumerated lazily by the system, so `AVCaptureDevice.DiscoverySession` at app start often returns only the built-in FaceTime camera. The first launch worked because the cable connection caused the system to wake the iPhone immediately; subsequent launches did not.

**Reason:**
This is the standard Continuity Camera quirk — the iPhone needs to be "activated" for video by the system before AVFoundation can see it, and that doesn't always happen at app launch.

**Impact:**
Users would think the app is broken on every cold launch.

**Follow-up — implemented in this same session:**
- `CameraCapture` now observes `AVCaptureDevice.wasConnectedNotification` and `wasDisconnectedNotification`. When a `.continuityCamera` arrives after the session has started with another device, it auto-switches. When the active device disconnects, it falls back to whatever is left.
- Added `CameraCapture.reconnect(preferredDeviceID:)` and a "Reconnect" button + device-picker menu in the HUD so the user can force a re-pick.
- `CameraSession` now polls `availableDevices` once per second so the picker reflects late-arriving Continuity Cameras.
- `currentDeviceName` is surfaced in the HUD so the user sees which camera is active.

Build still green, zero warnings.

---

## 2026-05-11 — M1 verified on hardware: 1 FPS @ 2 steps, 512×512 (below assumption)

**Decision / change:**
First successful run on the M5 base printed:

```
img2img: 0.997 s, 2 steps, strength 0.550000, 512x512
```

So **~1.0 FPS** for a single img2img pass with `disableSafety: true`, `reduceMemory: true`, `guidanceScale = 0`, dpm-solver, `.cpuAndNeuralEngine`, fp16 SD-Turbo at 512×512.

This is **below** the ≥3 FPS prediction in `ProjectDocument.md` §13 assumption #1. It's within 2× of the prediction, so the project is not dead — but it changes M3's design pressure significantly. Specifically:

- The temporal-blend strategy in §7 is now load-bearing, not optional. We were going to need it anyway, but now the live UI must be willing to display the camera frame for ~1 s while the next stylized frame computes.
- The "render at camera FPS, blend the latest stylized frame" pattern remains correct — Metal can still draw at 60 Hz; only the *replacement* of the stylized layer is throttled.
- 2 steps is already the floor for SD-Turbo (1 step degrades quality noticeably). Other levers we have: (a) drop spatial resolution to 384×384 (~30–40 % faster), (b) try `.cpuAndGPU` instead of `.cpuAndNeuralEngine` (sometimes faster on Apple Silicon for img2img — worth a 30-second A/B), (c) keep the VAE on GPU and only the UNet on ANE.

We don't tune those yet — first we want M2 (Vision) so we can see whether person-segmentation cost eats into the same budget.

**Reason:**
The whole point of the M1 benchmark was to get a real number. Now we have one. Replacing the wishful "≥3 FPS" with "≈1 FPS measured" lets every later milestone make decisions against reality.

**Impact:**
- `ProjectDocument.md` §13 assumption #1 is updated below to "1 FPS measured; design must tolerate this".
- M3 will be designed around a roughly 1 Hz stylized-layer update with 60 Hz passthrough underneath, plus temporal blend. Adding faster paths (resolution drop, compute-unit A/B) is added to the roadmap as P1 optimisations to attempt before any UI polish.
- Build still green, zero warnings.

**Follow-up:**
After M2 lands and we know Vision's cost, decide whether to attempt the 384×384 / `.cpuAndGPU` A/Bs before M3 or fold them into M3's optimisation pass.

---

## 2026-05-11 — M2 shipped: VisionKit (person seg + body pose), debug overlay live

**Decision / change:**
Built the Vision pipeline end-to-end behind the same actor + @Observable pattern we used for diffusion:

- `Artlify/VisionKit/VisionFrame.swift` — Sendable value type carrying the segmentation mask (`CVPixelBuffer?`, `OneComponent8`), an array of `VisionJoint { id, point, confidence }`, processing time, source dimensions, and timestamp. Marked `@unchecked Sendable` because `CVPixelBuffer` does not declare Sendable conformance — same exception we took for `CameraCapture`.
- `Artlify/VisionKit/VisionProcessor.swift` — Swift `actor` wrapping one `VNGeneratePersonSegmentationRequest` (quality `.balanced`, `OneComponent8` output) and one `VNDetectHumanBodyPoseRequest`. Both run inside a single `VNImageRequestHandler.perform([...])` call so they share image-decoding work. Joints below confidence 0.2 are dropped at the boundary.
- `Artlify/AppShell/VisionSession.swift` — `@MainActor @Observable` driver. Polls `CameraSession.latestPixelBuffer` at a target cadence (default 15 Hz, configurable), runs one pass at a time (re-entrancy is gated by the actor), maintains an EMA of processing time, exposes `latestFrame` for the UI.
- `Artlify/AppShell/PoseOverlay.swift` — SwiftUI `Canvas` overlay that draws the skeleton (16 hand-listed bones) + joint dots in normalized → view coordinates with a Y flip and aspect-fill compensation that mirrors the Metal renderer.
- `ContentView` now owns a `VisionSession`, starts it in `onAppear`, draws the overlay (toggleable from the HUD via a "Vision" button), and adds a status line: `vision: <ms> (<Hz>) · <N> joints · mask: yes/no`.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
M2 delivers the inputs M3 needs to do anything more interesting than full-frame img2img: a soft alpha mask of the person (so we can stylize *only* the person and keep the background passthrough sharp) and a skeleton (which M4 will use for prompt nudges and to detect motion for blend weighting). Building Vision *before* the diffusion live-loop means M3 can budget GPU/ANE time against a known Vision cost, not a guess.

`.balanced` segmentation quality is the documented sweet spot on Apple Silicon — far cleaner edges than `.fast`, ~3× faster than `.accurate`. We will revisit once we measure thermals at 30 minutes.

The polling driver (vs. fanning out CaptureKit's AsyncStream) keeps CameraSession unaware of downstream consumers and naturally enforces latest-frame-wins: if Vision is slow, intermediate frames are simply skipped, never queued.

**Impact:**
- One new module (`VisionKit/`) in the source tree.
- ~15 Hz Vision passes will eat some GPU; we'll see whether this hurts the 1 FPS diffusion number when both run together — that measurement is the M3 entry checklist.
- Pose overlay toggles off by default in production but is on for development; flip the `@State private var showVisionOverlay` default before shipping.

**Follow-up:**
Run the app, confirm pose overlay tracks the body smoothly, and read the `vision: <ms>` HUD line to record actual Vision cost on the M5. That number plus the existing 1 FPS diffusion number is the budget M3 will design around.

---

## 2026-05-11 — M1 first-run bugfix: VAE encoder rejected the camera frame

**Decision / change:**
First attempt to click **Stylize current frame** with the converted SD-Turbo bundle in place failed with:

```
run failed: The operation couldn’t be completed. (StableDiffusion.Encoder.Error error 0.)
```

`Encoder.Error` only has one case in `apple/ml-stable-diffusion`: `sampleInputShapeNotCorrect`, raised when the supplied `CGImage` width/height does not exactly match the encoder's `MultiArray (Float16 1 × 3 × 512 × 512)` input shape.

Root cause: `PixelBufferToCGImage.makeCGImage(...)` was producing the resized image by chaining `CIImage.transformed(by: scale)` → crop → translate → `CIContext.createCGImage(image, from: image.extent)`. The final extent could drift by a sub-pixel due to floating-point math, yielding a 511- or 513-pixel-wide `CGImage` and tripping the encoder's exact-shape guard.

Fix: rewrote the helper to (1) center-crop the source `CIImage` to a square in source pixel space, (2) materialize that square as a `CGImage` via `CIContext.createCGImage`, then (3) draw it into a fixed-size `CGContext` of exactly `Int(size.width) × Int(size.height)`. The output dimensions are now guaranteed integer-exact, regardless of source resolution or aspect ratio.

Also confirmed during debugging that the user's bundle is sandboxed at `~/Library/Containers/com.biru.Artlify/Data/Library/Application Support/Artlify/Models/sd-turbo/` (not the unsandboxed `~/Library/Application Support/...`). This is correct and intentional — `FileManager.url(for: .applicationSupportDirectory, ...)` from a sandboxed app already resolves to the container path, so `DiffusionPipeline.defaultModelDirectory()` and `revealModelFolder()` both already point at the right place. No code change needed there; just documenting it so future-us doesn't get confused.

**Reason:**
M1 cannot be verified without a successful encoder pass. The shape-mismatch was masking whatever the actual diffusion timing looks like.

**Impact:**
- Build still green, zero warnings.
- All future call sites of `PixelBufferToCGImage.makeCGImage(from:resizedTo:)` are now shape-safe — important because M3's live loop will hit this helper at >3 Hz.
- No behavioural change when `resizedTo` is `nil`: still returns the native pixel-buffer image.

**Follow-up:**
Re-run **Load model → Stylize current frame**. Expect a stylized 512×512 image plus a timing line in the HUD. Once we have a real number, update `ProjectDocument.md` §13 assumption #1 with the measured FPS so future milestones can lean on it instead of guessing.

---

## 2026-05-11 — M1 scaffold landed: SD Turbo via ml-stable-diffusion (code complete, awaiting model)

**Decision / change:**
Wired up the diffusion path end-to-end at the code level. Specifically:

- Added SwiftPM dependency on `https://github.com/apple/ml-stable-diffusion` pinned to `1.1.0+` (resolved 1.1.1, pulled `swift-argument-parser` 1.7.1 transitively). Edited `project.pbxproj` directly (added `XCRemoteSwiftPackageReference`, `XCSwiftPackageProductDependency`, target `packageProductDependencies`, project `packageReferences`, and a `PBXBuildFile` linking the `StableDiffusion` product into the Frameworks build phase).
- New module `Artlify/DiffusionKit/`:
  - `DiffusionPipeline.swift` — Swift `actor` wrapping `StableDiffusionPipeline`. Loads a model bundle from `~/Library/Application Support/Artlify/Models/sd-turbo/`, runs single-shot img2img passes with `guidanceScale = 0` (SD Turbo is trained without classifier-free guidance — using non-zero CFG produces garbage), `dpmSolverMultistepScheduler`, `reduceMemory: true`, `disableSafety: true`. Returns the `CGImage` plus a `DiffusionRunStats` value with wall-clock timing.
  - `CVPixelBuffer+CGImage.swift` — Reusable `CIContext` (Metal-backed when possible) for camera frame → square 512×512 `CGImage` with center-crop.
- New `AppShell/DiffusionBenchmark.swift` — `@MainActor @Observable` controller exposing `load`, `run(using:)`, prompt/steps/strength state, and a `revealModelFolder()` that opens Finder at the expected path.
- `ContentView` gained a benchmark panel: result thumbnail (220×220), prompt text field, steps stepper (1–8), strength slider (0.1–0.95), Load/Stylize buttons, and a status line showing `img2img: <ms> (<FPS>) · <steps> steps`.
- `CameraSession` now also caches `latestPixelBuffer` so the benchmark can grab the most recent frame without disturbing the render path.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
Per `ProjectDocument.md` §13 #1, the entire v1 design hinges on SD Turbo achieving ≥3 FPS on the M5 base. The cheapest way to validate that is a button that runs one img2img pass on a real camera frame and prints the wall-clock time. Building the live loop (M3) before measuring this would be premature.

The pipeline is a Swift `actor` so a second `generate` call cannot interleave with one in flight — exactly the shape M3 will need when the renderer is constantly asking "is the next AI frame ready?".

**Impact:**
- Adds two SwiftPM dependencies to the build graph; compile time noticeably longer (still <30 s clean).
- App still runs without any model installed — the UI shows "Reveal model folder" instead of "Load model" and prints the expected path. This is intentional: getting the model files is a separate, manual step (see follow-up below) and the team can keep iterating on UI/Vision work without it.
- Locked the design choice: **SD Turbo only** for v1 (CFG=0, dpm-solver, 2 steps default). SDXL Turbo and ControlNet remain in `Roadmap.md` "Post-v1 / Conditional".

**Follow-up:**
To actually run the benchmark, the team needs to convert SD Turbo to CoreML once and drop the resulting `.mlmodelc` bundle (plus `vocab.json`, `merges.txt`) into `~/Library/Application Support/Artlify/Models/sd-turbo/`. The conversion is a one-time Python step from `apple/ml-stable-diffusion`:

```bash
# in a Python venv with apple/ml-stable-diffusion installed
python -m python_coreml_stable_diffusion.torch2coreml \
  --convert-unet --convert-text-encoder \
  --convert-vae-decoder --convert-vae-encoder \
  --model-version stabilityai/sd-turbo \
  --bundle-resources-for-swift-cli \
  --attention-implementation SPLIT_EINSUM \
  -o ./out
# then: cp -R out/Resources/* ~/Library/Application\ Support/Artlify/Models/sd-turbo/
```

Once installed, click **Load model** → wait for "model loaded" → click **Stylize current frame** and read the FPS. If it lands in the 3–6 FPS band predicted in `ProjectDocument.md` §3, M1 is verified and we proceed to M2 (Vision integration). If it lands below 2 FPS, fall back to 384×384 or an LCM-distilled variant before any further UX work, as `Roadmap.md` already calls out.

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
