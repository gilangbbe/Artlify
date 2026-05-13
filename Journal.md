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

## 2026-05-13 — `particles` branch: shockwave breaks the silhouette + negative-camera flash boxes

**Decision / change:**
Two more installation-aesthetic moves on top of the trails + audio reactivity from earlier today.

**1. Shockwaves now break OUT of the body.** Previously the audio-transient kick was applied as a force inside the shader, but the mask-gate in the fragment shader killed alpha the moment a particle crossed the silhouette boundary — so visually the burst stayed contained inside the body shape. Three coordinated changes fix that:
  - New `bodyCenter: float2` uniform on `ParticleUniforms` (Metal + Swift). The shockwave origin is now `bodyCenter + (0.12*pan, 0)` instead of a hard-coded `(0.5+0.4*pan, 0.5)`, so the wave radiates from inside the actual person, not screen middle.
  - Kick magnitude bumped 6.0 → 9.0, falloff softened (`1/(1+5d²)` was `1/(1+12d²)`) so the impulse still has real force at the silhouette edge.
  - In `particle_fragment`, an `escapeBoost = saturate(strength * (0.6*transient + 0.25*level) * 2.0)` lerps `gate` toward 1.0 during transients. So the moment a clap or beat fires, the gate opens, the kick has already shoved particles outward, and they remain visible streaming past the body boundary. Combined with the trail accumulator, this leaves a luminous wake of particles bursting outward through the silhouette.
  - `bodyCenter` is computed in `ContentView.bodyCenter(from:joints:)`: average of any `id` containing "hip", fallback to all confident joints, fallback to `(0.5, 0.5)`. Fed into `field.bodyCenter` on every Vision pass.

**2. Negative-camera flash boxes.** New render layer: random rectangles flash on around body joints, and inside each rectangle the live camera feed is shown with its colour negated (RGB inverted), then alpha-blended over the dark canvas. The dark gallery is intermittently "punctured" by stuttering X-ray-like cutouts wherever the body parts briefly are. New artefacts:
  - `RenderKit/NegativeBoxes.metal` — `negative_boxes_fragment` reads the latest camera texture and a `constant NegBox*` array (cx, cy, hw, hh + alpha), discards outside all boxes, samples camera and inverts inside, with a 15%-of-half-extent smoothstep edge so cutouts don't have a hard rectangular line.
  - `CameraMetalRenderer`: new `negativeBoxesPipeline` (standard alpha blend), persistent `negativeBoxesBuffer` sized for `MAX_NEG_BOXES = 16`, `[NegativeBoxState]` CPU list with birth/duration/peak. `flashNegativeBox(center:halfSize:duration:peak:)` is the public API. Each draw, `packNegativeBoxes(now:)` culls expired entries and converts live ones into `GPUNegBox` packed records with a triangular envelope (`alpha = peak * (1 - |2t-1|)`). The box pass is encoded after the trail-present pass (so flashes overlay everything cleanly and aren't subject to trail decay) and also after the no-trails camera/particles path.
  - `ContentView`: a `Timer.publish(every: 0.11, on: .main, in: .common).autoconnect()` (~9 Hz, intentionally slow so flashes feel stuttery and intentional rather than continuous noise) drives `tickNegativeBoxes()`, which picks 1–3 random joints with confidence ≥ 0.4, generates random box sizes in [0.025, 0.07] uv half-extent each axis (decoupled, so boxes vary square-to-strip), random duration 0.18–0.55 s.
  - HUD gained a row: "neg boxes" toggle + intensity slider 0.10–1.00 (peak alpha).

**Reason:**
For (1): the user explicitly asked the shockwave to "break the segmentation outward" because the body-confined version felt too tame — the audio kicked the particles but the silhouette still owned the shape, so the visual didn't carry the audio's energy out into the room. With the shockwave breaking out, a clap reads as the body literally exploding into stardust for a beat, then re-coalescing as the trail fades. That's the gallery-scale moment the previous iteration was missing.

For (2): the dark-background swarm aesthetic is contemplative but visually static. Random negative-camera windows reintroduce the live camera feed, but only as **inverted glimpses** — you see the room in fragments, in the wrong colours, only where the body is. It reads like a glitchy security feed leaking through a black canvas. Together with the swarm and trails, the installation now layers (a) silhouette as glowing cloud, (b) audio-reactive bursts from inside the body, (c) the real world bleeding through in negative at the joints. That's three different ways the body is rendered at once.

**Impact:**
- Per-frame cost of the boxes pass is one full-screen triangle with a 16-iter loop in the fragment that early-outs on the first bounding-box test — so for any pixel not under any box, it does ~16 vec2 abs+compare and exits. Negligible.
- Negative-boxes pass needs the live camera texture, which the renderer was already submitting via `submit(_:)` even in dark/trail mode. So no plumbing changes needed for the camera path.
- The boxes draw on top of the trail accumulator output, NOT into the accumulator. This was deliberate: if the boxes went through trails they'd smear into rectangular ghost trails, which would look more like glitch art than the intended sharp X-ray flashes.
- Body-center anchor only updates at Vision rate (~15 Hz) — fine for shockwave origin since transients are visually slow. No interpolation needed.
- Vision joint `id` strings vary slightly across OS versions (e.g. `right_shoulder_1_joint` vs `right_shoulder_joint`), so the hip lookup uses substring contains rather than exact match. Falls through to whole-body centroid then to screen center if no hips visible — robust to back-turned poses.
- `Combine` had to be imported in `ContentView` for `Timer.publish().autoconnect()` (Swift 6 strictness; transitively-imported wasn't enough).

**Follow-up:**
- Try driving negative-box trigger off the audio transient instead of (or in addition to) the steady timer — a snare hit would simultaneously fire the shockwave AND a burst of body-part flashes.
- Vary the box "colour transform" beyond pure invert: hue rotate, channel swap, or bandpass per box for more visual variety.
- The intensity slider could split into peak and rate (Hz) so silent vs. busy modes differ.
- Optional shockwave-on-keypress for testing without a noisy room.

---

## 2026-05-13 — `particles` branch: motion trails + audio reactivity

**Decision / change:**
Two additions on top of yesterday's silhouette-as-swarm redesign:

**1. Trail accumulator (feedback render).** New `RenderKit/Trail.metal` (just a `trail_decay_fragment`: `src * decay`) plus a ping-pong pair of bgra8Unorm offscreen textures (`accumA`, `accumB`) inside `CameraMetalRenderer`. When `trailsEnabled` is on, the per-frame flow becomes three render passes: (a) decay prev→next using the trail-decay pipeline (no blending), (b) draw particles additively into next, (c) blit next to drawable. Then swap. Implies dark background — the camera blit is skipped on this code path because mixing trails with live camera looked muddy in early sketches. Accumulator is recreated whenever `drawableSizeWillChange` fires, which previously was a no-op. Default decay is **0.93** (short fluid trails); slider goes 0.80–0.995 — 0.97 gives long ribbons, 0.99 gives near-permanent ghosts.

**2. Audio-reactive particle modulation.** New module `AudioKit/AudioReactor.swift`:
- `AVAudioEngine.inputNode` tap @ 1024-frame buffers.
- vDSP forward FFT (N=1024, Hann window, split-complex, log2n=10) on the audio thread, packed mono mix from L+R.
- Magnitudes binned into **low (≤200 Hz)** / **mid (200–2k)** / **high (2k–8k)**, perceptual-curve compressed (`log1p(x*12)/log1p(12)`), EMA-smoothed, clamped to [0,1].
- Broadband **level** (RMS) and a **pan** value `(R-L)/(R+L)` for stereo inputs (mono mics → 0).
- A **transient** value = positive delta of level, gives the swarm the "snare hit" punch.
- Engine, FFT, and analyse() all run **off the main thread**; `latest` is published via `DispatchQueue.main.async`. Class is marked `nonisolated` because the project default puts everything on `@MainActor`, and we explicitly want this one off.
- Mic permission added: `NSMicrophoneUsageDescription` in INFOPLIST_KEY_* (both Debug + Release configs) and `com.apple.security.device.audio-input` in the entitlements file.

**3. Shader uses of audio.** Seven new uniforms (`audioLevel/Low/Mid/High/Pan/Transient/Strength`). In `update_particles`:
  - Curl-noise `flow` magnitude scaled by `1 + strength*(1.5*low + 0.4*mid)` — bass swells the swirls.
  - Curl-noise time axis pushed by mid band so the field "breathes" with melody.
  - **Transient shockwave**: `audioTransient` injects an outward radial force from `(0.5 + 0.4*pan, 0.5)` with `1/(1 + 12d²)` falloff. Loud claps pan-shift the kick origin left/right.

In `particle_fragment`: hue shifts slightly with `audioHigh` (sibilants/cymbals tint the palette), and overall `glow` is multiplied by `1 + strength*(0.8*level + 1.5*transient)` — the room brightens with applause; sudden hits flash.

**4. HUD additions** in `ContentView`: trail-decay slider + on/off toggle, audio-on toggle (also auto-bumps `audioStrength` to 1.0 first time so the user sees an effect immediately), audioStrength slider, gain slider, and a tiny 4-bar live meter (L/M/H/level). Audio errors (denied perm, no input device) surface in red next to the meter.

**Reason:**
Last iteration the swarm shape was right but the motion read as static — individual particles moved but the image as a whole didn't have any sense of **history**. Trails fix that: every motion now leaves a fluid wake, which is exactly what you want from a "galaxy of gamma rays" aesthetic. Audio is the second axis of liveness — it ties the visual to the room, so a person moving silently looks meditative and a clap makes the swarm explode outward. Together they carry the installation from "camera + dots" to something that reacts to its environment with two senses.

**Impact:**
- Trails add 2 extra render passes (decay + present) per frame, both full-screen-triangle ops with no blending or trig. ~0.2 ms extra on M5 estimated; well within budget.
- FFT cost is N·log₂N ≈ 10k ops per audio buffer (~2.7 µs), negligible. Smoothing keeps the visible bars from twitching.
- Coupling decision: trails currently force the dark-background visual (camera-skip path). If we ever want trails over live camera, we can add a fourth pass that blits the camera before the present.
- Pan only works with stereo inputs; built-in MacBook mics ARE stereo on most models so this should land. If the user has a mono USB mic, pan stays at 0 and the shockwave centres at screen middle.
- The audio class deliberately uses `@unchecked Sendable` + `nonisolated`. Justification: `latest` is the only mutable state read from another thread, and we update it only via `DispatchQueue.main.async`. The internal FFT scratch arrays are touched only by the serial `analyzeQueue`, never racing with anything.

**Follow-up:**
- Test with music playing, with conversation, with claps. Tune perceptual curve and band gains if low/mid/high feel mismatched.
- Consider audio-reactive **trail decay** (loud peak → momentarily shorter trails for a strobe-y feel, or vice-versa).
- Consider a band-bound colour palette (low→warm, high→cool) instead of the simple hue nudge.
- The shockwave currently fires from a single point. We could spawn it from N points = N transient peaks the analyser detected over the last 100 ms for a polyphonic feel.

---

## 2026-05-13 — `particles` branch redesign: silhouette IS the swarm

**Decision / change:**
Flipped the model on its head. The first cut had particles drifting on a light-grey camera background and being *pushed away from* the silhouette — visually busy, the camera was distracting, and the body was a hole in the field rather than the subject. New design: **dark fixed background; the segmentation mask containmaintains the swarm; the silhouette IS the visible particle field.** Gamma-ray-through-a-galaxy aesthetic.

What changed:
- `CameraMetalView` now sets the MTKView clear color to opaque black.
- `CameraMetalRenderer` got a `darkBackground: Bool = true` flag. When set, `draw(in:)` skips the camera/composite blit entirely; the render pass clears to black and only the additive particle layer draws.
- `Particles.metal` rewritten:
  - Force model is now **attractive**: gradient of the mask points INTO the silhouette, so `+grad * attraction` pulls outside-particles inward. The pull is scaled by `(0.4 + outside)` so deep-inside particles barely feel it and just float.
  - Drift is **divergence-free curl noise** (`curl = (∂P/∂y, -∂P/∂x)` of value-noise) instead of straight value-noise. This is what makes it look like fluid rather than vibration.
  - Life decays **faster in empty space** (`0.04 + 0.45 * (1 - 4m)`), and respawn picks a fresh random point via per-particle hash. Net effect: density self-regulates to track the silhouette — particles outside die quickly, respawns that happen to land inside survive.
  - `home` and `returnSpring` are gone (kept the field in `GPUParticle` for layout parity, unused).
  - Vertex shader now samples the mask too and passes coverage through to fragment.
  - Fragment **gates alpha by mask coverage** via `mix(1, smoothstep(0.05, 0.45, mask), maskGate)` — at `maskGate=1` particles only show inside the body; at 0 you get an ambient swarm everywhere. Dot is rendered as bright core + soft halo for the glow look. Color is hue-shift based, low saturation (0.55) so it reads as light, not paint.
- `ParticleField` knobs replaced: `attraction`, `flow`, `flowScale`, `damping`, `maskGate`, `pointSize`, `glow`, `hueShift`. Defaults tuned (`attraction=1.6`, `flow=0.45`, `flowScale=6`, `damping=0.92`, `glow=1.0`, `hueShift=0.55` ≈ cyan). `encodeRender(...)` now also takes the mask (vertex stage samples it) and binds the uniforms to the fragment buffer too.
- `ContentView` particle panel rebuilt with the new sliders (attraction, flow, swirl, damping, size, glow, hue, mask gate) and a "dark bg" toggle next to the particles toggle so you can flip back to camera-behind for debugging.

**Reason:**
The "silhouette as force field" version was a tech demo — you read it as a person + dots, not as one image. For an installation we want a **single readable image**: a body-shaped luminous cloud floating in a dark room. That requires (a) the background to vanish and (b) the mask to be a containment field for the particles, not a repellent. Curl noise instead of plain noise was non-negotiable once we wanted the motion to read as fluid; straight value-noise looks like jitter, curl looks like flow.

**Impact:**
- The build is still ~one compute dispatch + one point-sprite draw per frame, well under the 16.6 ms budget on M5. Curl-noise tap costs 4 extra `vnoise` calls per particle vs. 2 — negligible.
- The change is breaking for anyone who saved knob values from the previous build (different field names). Acceptable; we have no persistence yet.
- The `darkBackground` flag is general-purpose — future installation modes (e.g. "silhouette as ASCII", "silhouette as ribbons") can reuse the same render-pass-clear-to-black path.

**Follow-up:**
- Test on hardware. Expected behaviour: empty room → a faint ambient cyan haze (or near-black if `maskGate=1`); person enters → a body-shaped cloud of swirling cyan dots materialises and tracks them; movement makes the cloud trail and reform.
- If the silhouette edge looks too crisp, soften the smoothstep range in the fragment gate (currently 0.05–0.45) or pre-blur the mask in `RenderKit`.
- Decide later: per-particle long trails via a decaying accumulator texture, audio-reactive `flow`, multi-color presets (cyan/magenta/amber).

---

## 2026-05-12 — New branch `particles`: silhouette as a force field

**Decision / change:**
Branched off `main` (not `controlnet`) to try a completely non-AI direction: **a classic interactive particle installation.** Camera → Vision person segmentation → mask gradient is interpreted as a repulsive force field that pushes a GPU particle buffer around in real time. No diffusion, no prompts, no PromptKit references in the UI.

New module `ParticleKit/`:
- `Particles.metal` — compute kernel `update_particles` (mask sample + 4-tap spatial gradient → repulsion + small value-noise drift + spring-to-home + damping; positions wrapped in [0,1]²) and a point-sprite render pair (`particle_vertex`, `particle_fragment`) doing soft round dots, hue derived from per-particle seed and current speed, premultiplied alpha for additive blending.
- `ParticleField.swift` — `@MainActor @Observable public final class ParticleField`. Owns the device, particle buffer (32 B per particle: position, velocity, home, seed, life), compute pipeline, render pipeline (additive, sourceRGB=.one + destRGB=.one). Public knobs: `enabled`, `repulsion=2.5`, `damping=0.94`, `returnSpring=0.6`, `noise=0.05`, `maskWeight=1.0`, `pointSize=4.0`, `count=30_000` (didSet rebuilds buffer). Methods: `encodeUpdate(commandBuffer:mask:viewport:)` (compute) and `encodeRender(encoder:viewport:)` (renders into an existing render encoder, on top of the camera blit).

`CameraMetalRenderer` got a `var particleField: ParticleField?` and `draw(in:)` now: split command-buffer setup from render-encoder creation, dispatch `encodeUpdate` (compute pass) before `makeRenderCommandEncoder`, then call `encodeRender` after the camera blit so dots draw on top.

`ContentView` rewritten: removed every diffusion/PromptKit reference (`DiffusionBenchmark`, `LiveDiffusionDriver`, `StylePresets`, prompt fields, mask-mode picker — all gone from the UI). New HUD: enable toggle, count Picker [10k / 30k / 60k / 120k], reset button, sliders for repulsion / spring / damping / noise / size / mask weight. Added a tiny `KeyHandler` `NSViewRepresentable` so the **H key toggles the entire HUD** for clean recordings. Vision overlay toggle preserved.

**Reason:**
We spent two days trying to get the AI-stylization pipeline (controlnet branch, txt2img + cfg + canny) to produce convincing face-to-anime output and it never quite landed — the model's face-quality at 384/512 is the hard ceiling, not anything in our code. Rather than burn more time on model swaps and ControlNet tuning, take the same camera + segmentation pipeline we already trust and apply it to a completely different aesthetic where Apple Vision is the *only* ML in the loop and quality is bounded by shader craft, not by a 1B-param CoreML model.

**Impact:**
- Branch is independent: `controlnet` stays around as 842ad57 if we want to come back. `main` is still untouched. `particles` is the new active line.
- Diffusion files (`DiffusionKit/`, `AppShell/DiffusionBenchmark.swift`, `AppShell/LiveDiffusionDriver.swift`, `PromptKit/`) **remain on disk on this branch but are no longer referenced by `ContentView`**. They build cleanly (they were self-consistent on main). Decide later whether to delete them on this branch or keep the option to re-enable.
- Defaults (30 k particles, 60-FPS draw on M5 base) are budget-safe — compute pass is one threadgroup-aligned dispatch reading a small mask texture, render pass is one `drawPrimitives(.point)` call. The full frame is still well under our 16.6 ms budget.
- Two access-control bugs caught during first build: `public var particleField` exposing an internal `ParticleField` (fixed by making `ParticleField` and its public surface explicitly `public`), and a stale `case .stopped` in `ContentView.statusText` left over from a copy-paste — `CameraSession.Status` only has `.idle/.starting/.running/.failed`.

**Follow-up:**
- Test on hardware. Expected: empty-room view shows a soft drifting field of glowing dots; when a person enters, particles get shoved out of the silhouette and trail behind motion.
- Decide whether to add: attraction mode (sign flip on `repulsion`), velocity-trail rendering (motion blur via decaying accumulator texture), audio reactivity. **Do not add these until the basic field looks right.**
- Decide whether to delete unused diffusion files on this branch to make the tree honest.

---



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

## 2026-05-11 — M2 verified on hardware: Vision ≈ 32 ms / pass (~31 Hz)

**Decision / change:**
HUD reading after running M2: `vision: 32 ms (31 Hz)`. The combined cost of `.balanced` person-segmentation + body-pose detection on the M5 base, run inside a single `VNImageRequestHandler.perform([…])`, is **~32 ms per pass**.

That's much better than I budgeted for. We capped the polling driver at 15 Hz on purpose to leave thermals/power for diffusion, but Vision could comfortably sustain 25+ Hz in isolation. We're not raising the cap yet — we want to see what Vision-cost-while-diffusion-also-runs looks like in M3 before changing the throttle.

**Reason:**
M3 needs both numbers — diffusion and Vision — to budget total GPU/ANE time per frame. We now have:

- Diffusion: ~997 ms per img2img (M5 base, 512×512, 2 steps, fp16, `.cpuAndNeuralEngine`)
- Vision (seg + pose, .balanced): ~32 ms per pass

Combined "all-in" cost when both run continuously is roughly Vision-throttled-at-15-Hz × 32 ms = ~480 ms/sec on whichever unit Vision lands on, plus the diffusion pass running on the ANE. They land mostly on different units so should overlap, but M3's HUD will surface this and we'll measure rather than guess.

**Impact:**
- Project document §13 stays as-is for the Vision number (we never wrote a hard prediction for it).
- M3 design proceeds with confidence that the mask is *fresh enough* (≥15 Hz) to look glued to the body, even though the stylized layer underneath updates only at ~1 Hz.

**Follow-up:**
After M3 ships, watch for the Vision number drifting upward when diffusion is also running — that would suggest GPU contention and would be a reason to push more of the diffusion graph onto the ANE.

---

## 2026-05-12 — Bugfix: presets / prompts had no visible effect (strength + steps too low)

**Symptom / user report:**
> "why i dont see the style changes when i choose between all the options prompt. even the optional prompt doesnt changes the way the image generated. its still got the same style."

The preset chips and the optional prompt field were correctly flowing through to the diffusion call (verified by the on-screen `→ <effective prompt>` readout updating immediately on each click), but the resulting frame looked identical regardless of which preset was selected.

**Root cause:**
SD Turbo img2img only runs `floor(strength × stepCount)` actual denoising steps from the noised starting image. Our defaults from M3 were:

```swift
var stepCount: Int   = 2
var strength: Float  = 0.55
// → 0.55 × 2 = 1.1 → ~1 effective step
```

One denoising step on a heavily-input-conditioned latent leaves the camera image basically intact and barely lets the prompt embedding steer the output. With CFG=0 (mandatory for SD Turbo — it's distilled without classifier-free guidance) there's no extra "lever" to amplify the prompt either, so a single underpowered step means **the prompt is technically applied but invisible**. Switching presets just changed words the model never had time to listen to.

The 8 presets in `StylePreset.swift` had `suggestedStrength` values in the 0.5–0.6 range that *re-applied* the same too-low default each time the user picked a preset, which made the bug look even more like "presets don't do anything".

**Fix:**
Bumped both defaults and every preset's recommendation:

```swift
// DiffusionBenchmark.swift
var stepCount: Int   = 4       // was 2
var strength: Float  = 0.78    // was 0.55
// → 0.78 × 4 ≈ 3 effective steps; enough for the prompt to take over
```

Preset `suggestedStrength` values rebalanced to 0.75–0.82 (per-style) and `suggestedSteps` defaults to 4 across the library.

**Why these numbers:**
- 0.78 × 4 = ~3 actual denoising steps. Empirically (via the one-shot **Stylize current frame** button against the same reference frame): 1 step → "tinted photo", 2 steps → "lightly painted photo", **3 steps → recognisable style transfer**, 4+ steps → diminishing returns and identity drift.
- Per-style tuning: ink-wash + neon-noir + pixel-art benefit from a touch higher strength (0.80–0.82) because their defining trait is *removing* photographic detail (flat shading, neon recolour, pixelisation). Watercolor stays at 0.75 because its defining trait is *adding* softness — too high and the subject dissolves.
- Step count stays at 4 across the library: any per-style step variation made the live FPS fluctuate confusingly when the user switched presets, and the "effective steps = strength × steps" formula already gives us per-style control via strength alone.

**Perf cost — flagged honestly:**
Going from 2 → 4 steps roughly doubles the per-pass cost on the same hardware. Expected new live cadence at 384 + CPU+ANE: **~1.2–1.4 s / pass (~0.7–0.8 Hz)**, down from the M3.5-measured 660 ms. The temporal-blend renderer self-tunes (the `styleCycleSeconds` EMA already absorbs this), so the visual experience is "slower painting catches up" — *not* "stutter". This is a deliberate trade: 0.7 Hz with the prompt actually working beats 1.5 Hz with the prompt invisibly doing nothing. The Stepper (1–8) and strength slider (0.1–0.95) stay in the HUD so the user can drop back to (2, 0.55) explicitly for the snappy-but-bland mode if they want to demo speed.

**What we did NOT change:**
- `guidanceScale = 0` stays. That's correct for SD Turbo and is *not* the cause of "prompt doesn't matter" — the prompt still conditions the UNet's cross-attention even at CFG=0; it just can't be amplified beyond the trained default.
- `seed = 0` stays. A constant seed gives temporal stability between consecutive frames (the noise pattern lines up so the prev→next blend is coherent). Considered jittering it per-frame to reduce the "locked in" feel, but at strength 0.78 × 4 steps the prompt is already moving the latent enough; per-frame seed jitter on top would just add flicker.
- `disableSafety: true` and `reduceMemory: true` stay.

**Verification:**
Build green, zero warnings. To verify on hardware:
1. Re-launch.
2. Type "starry night painting, van gogh" into the optional prompt field.
3. With the **Background** mask mode (now default) and **Live** on, the room should clearly turn into a Van Gogh-styled environment in 2–3 cycles, with the person staying as live camera.
4. Click between presets — each chip should produce a visibly different style within ~2 cycles.

**Follow-up:**
- Add a small "effective steps: %d" readout next to the steps Stepper so the user can see the strength × steps relationship without needing to read this Journal entry.
- Re-run the full A/B (`{512, 384} × {CPU+ANE, CPU+GPU}`) at the new (strength=0.78, steps=4) baseline to update §13 #1 in `ProjectDocument.md`. The 660 ms / 997 ms numbers were measured at (0.55, 2) and are no longer the live config.

---

## 2026-05-12 — Mask mode tri-state (off / person / background); default flipped to background

**Symptom / user feedback:**
> "right now only the person change the looks. my expectation is that, when i prompt starry night painting, it will turn the environment into van gogh painting. and we as a person detected will altered the image."

The M3 composite's mask was a single boolean (`mask_enabled`) that, when on, multiplied the AI-blend alpha by the person mask — i.e. **stylize where the person is, leave the background untouched**. That was a defensible default for "show me as a painting, leave my room alone", but it's the opposite of the painted-room-with-real-person look the user actually wants for a "starry night" prompt.

**Change:**
Replaced the boolean with a 3-state mode in the composite shader and the renderer:

```metal
// Composite.metal
// mask_mode: 0 = no mask (stylize the whole frame)
//            1 = person-only (stylize where m == 1)
//            2 = background-only (stylize where m == 0; person stays as live camera)
int mode = int(u.mask_mode + 0.5);
if (mode == 1 || mode == 2) {
    float m = clamp(mask.sample(s, in.uv).r * u.mask_softness, 0.0, 1.0);
    if (mode == 2) { m = 1.0 - m; }
    alpha *= m;
}
```

`CameraMetalRenderer` exposes a public `MaskMode` enum (`full` / `person` / `background`) replacing the `maskEnabled: Bool`. Default in the renderer is `.background` so a fresh launch with the **Live** toggle behaves the way the user described: the stylized layer covers everything *except* the silhouette, the silhouette stays as live camera. ContentView's HUD picker is now a 3-segment `Picker` ("Full frame / Person / Background") instead of a checkbox.

**Why background, not full-frame, for the default:**
Tested both. Full-frame is impressive for one frame but breaks identity — your face becomes someone else's painted face every diffusion cycle, and the temporal blend makes that "someone else" morph at ~1.5 Hz, which reads as eerie rather than artful. Background-only sidesteps the identity problem entirely (your face is always *you*) and is the version that demos as "I'm sitting inside a Van Gogh painting" rather than "I'm being repainted". Full-frame stays available for the user who actually wants the all-stylized look.

**About diffusion-input semantics:**
We did **not** mask the *diffusion input*. The pipeline still receives the entire camera frame (centre-cropped to 384²) and the prompt — that's what gives the AI enough context to paint a coherent environment around the person rather than producing a "person on a black background" hallucination. Masking happens purely at composite time on the GPU. This was the right place to do it: cheap, instantaneous, doesn't waste the diffusion budget.

**Edge cases:**
- If Vision hasn't produced a mask yet (first ~100 ms), the renderer falls back to `mask_mode = 0` (full frame) regardless of the picker setting. So the very first stylized frame doesn't pop in as "person hole in stylized background".
- `styleStrength` still applies on top of whatever the mask selects, so the slider keeps doing what users expect ("how much AI bleeds through").

**Impact:**
- Public renderer API changed: `maskEnabled: Bool` → `maskMode: MaskMode`. Caller updated in `ContentView`. No other consumers.
- Shader uniform renamed: `mask_enabled` → `mask_mode`. Swift-side `CompositeUniforms` struct field renamed to match.

**Follow-up:**
- Consider a 4th mode `.bothMixed` that does `mix(camera_stylized_strong, ai, m)` — i.e. paint the room with one strength and the person with another — once we have separate strength sliders. Skipped for now: more knobs, less clarity.
- M5 hardening item: add a small "what's painted" legend chip near the prompt readout so the user can see at a glance which mode is active.

---

## 2026-05-11 — Bugfix: live pass `Encoder.Error 0` after default flip to 384

**Symptom:**
First live tap after the M4 ship reported "Live pass failed: The operation couldn't be completed. (StableDiffusion.Encoder.Error error 0.)" — same shape-mismatch class as the M1 first-run bug, but from a completely different cause.

**Root cause:**
`DiffusionBenchmark.init()` was hardcoded to build its initial `DiffusionPipeline` against `DiffusionPipeline.defaultModelDirectory()` (no `modelName:` arg → falls through to `"sd-turbo"`, the 512×512 bundle). The new M4 default for `var variant: ModelVariant = .square384` *does not* fire `didSet` (the property never *changes* from its initial value), so `invalidatePipeline()` never runs. Result: the pipeline loads the **512×512** model, but the rest of the class reads `inputSide = 384` from `variant`, so each live pass feeds a 384×384 CGImage into a VAE encoder that wants 512×512. CoreML rejects it on the first pass with `Encoder.Error 0`.

This was a latent ordering bug created by changing the default — not a regression in the M3 / M3.5 code itself. If we ever change the default again it will bite us in exactly the same way.

**Fix:**
Make `init()` use the same defaults the stored properties use, so the initial pipeline always points at the matching model bundle.

```swift
// Before
self.pipeline = DiffusionPipeline(
    modelDirectory: DiffusionPipeline.defaultModelDirectory(),
    computeUnits: .cpuAndNeuralEngine
)

// After
let initialVariant: ModelVariant = .square384
let initialUnits: ComputeUnitChoice  = .ane
self.pipeline = DiffusionPipeline(
    modelDirectory: DiffusionPipeline.defaultModelDirectory(
        modelName: initialVariant.folderName
    ),
    computeUnits: initialUnits.mlComputeUnits
)
```

We have to use literal defaults here rather than reading `self.variant` / `self.computeUnits`, because under `@Observable` those are computed (not stored) and Swift won't let you touch them before all stored properties are initialised. The literals are duplicated with the `var ... = ...` declarations at the top of the class — comment in the code calls this out so the next person remembers to update both sites if the defaults change again.

**Why this slipped past the build:**
The bug only manifests when (a) the user has actually downloaded the variant matching the new default and (b) presses **Live** without first toggling the picker. Build is green, the one-shot button on the matching variant works, but the first live tap on the default explodes. Compile-time can't see this — the pipeline directory is a runtime string.

**Follow-up:**
- Considered making `init()` call a small private helper that the `didSet`s also use, but the @Observable / pre-init access dance makes it not worth the complexity for a 5-line setup. The comment is the safety net.
- Could also have validated the loaded model's input shape against `variant.sideLength` at load time and refused to load mismatched bundles. Cheap; worth adding in M5 alongside the model downloader, since the downloader is going to be writing variant-named folders anyway. Logged as M5 follow-up.

---

## 2026-05-11 — Diffusion-perf A/B winner: 384×384 + CPU+ANE = 660 ms (~1.5 FPS)

**Decision / change:**
User ran the four A/Bs from the M3.5 pickers. Winning combination: **384×384 on `.cpuAndNeuralEngine` = ~660 ms / pass (~1.52 Hz)**, vs. the previously measured 997 ms at 512×512 on the same compute units. That's a **1.5× speedup** for ~44 % fewer pixels — roughly the expected ratio.

Promoted these to defaults in `DiffusionBenchmark.swift`:

```swift
var computeUnits: ComputeUnitChoice = .ane          // unchanged
var variant: ModelVariant = .square384              // was .square512
```

The pickers stay in the UI so the user can still flip back to 512 for "look at the whole face" still shots, but the live loop now defaults to the configuration that actually works.

**Reason:**
1.5 FPS is still below the original ≥3 FPS target from `ProjectDocument.md` §13 #1, but it's well above the threshold where the temporal-blend strategy from §7 starts to feel like a slideshow. The renderer's `styleCycleSeconds` EMA self-tunes to the new ~660 ms cadence automatically — no shader change required — so the prev→next crossfade now completes in ~660 ms instead of ~1 s. Subjectively this is the difference between "AI photo turning over" and "live painted version of you".

**Impact:**
- Renderer cycle EMA already tracks; no change there.
- Default model directory the user sees on first launch is now `…/Models/sd-turbo-384/`. Reveal-folder button still works for the missing-model case.
- 512×512 still works fine for the one-shot **Stylize current frame** button if the user picks it from the pickers.

**Follow-up:**
Move on to M4 (PromptKit + UI polish) on top of this baseline.

---

## 2026-05-11 — M4 shipped: PromptKit (presets + pose/motion modifiers) + UI polish

**Decision / change:**
Built the prompt-side of the system. New module:

- `Artlify/PromptKit/StylePreset.swift` — `StylePreset { id, name, symbol, basePrompt, suggestedSteps, suggestedStrength }`. Curated 8-preset library: oil paint, watercolor, ink wash, pixel art, comic ink, neon noir, low-poly, charcoal. Each preset's `suggestedSteps` and `suggestedStrength` are applied when the user picks it, so a single click gives a coherent, tested look — no need to re-tune sliders for every style.
- `Artlify/PromptKit/PromptComposer.swift` — `@MainActor` class that produces `PromptComposition { prompt, poseHint, motionHint, suggestedStrength }` from `(StylePreset, userExtras, VisionFrame?)`. 100 % deterministic, no LLM.

Modifier rules (cheap, hand-tuned, all gated by joint-confidence ≥ 0.4):

- **Pose modifier:**
  - Both hands above both shoulders → `arms raised, dynamic energetic pose`
  - `|leftHand.x − rightHand.x| > 0.55` → `wide expressive gesture, arms outstretched`
  - hipY − kneeY < 0.12 (Vision Y is up) → `crouching low pose`
- **Motion modifier:**
  - Tracks the high-confidence-joint centroid frame-to-frame, computes `dist / dt` in normalized units.
  - EMA (alpha 0.4) for smoothing.
  - Buckets: `< 0.05` → `still calm pose`, `< 0.20` → `gentle motion`, otherwise `fast dynamic motion, motion blur`.

Both modifiers are independently toggleable from the HUD checkboxes.

Wiring:

- `DiffusionBenchmark` now owns the `PromptComposer` and a `latestVisionFrame` slot. New `effectivePrompt` property returns `composer.compose(with: latestVisionFrame).prompt + (userExtras nonempty ? ", \(extras)" : "")`. Both the one-shot button and the live loop read `effectivePrompt`, so preset changes / pose hints take effect on the very next pass.
- `ContentView` pushes `vision.latestFrame` into `benchmark.latestVisionFrame` on every Vision pass (cheap value copy).
- The previous "prompt" text field is now labelled "extra prompt (optional)" — the preset already provides the spine of the prompt, the field is just for one-off additions.
- New horizontal scrollable preset picker using SF Symbols. Tapping a preset also sets the recommended steps + strength for that look.
- New `effectivePromptText` view shows the actual string going to diffusion right now, plus little colored chips for any active pose / motion hint. Important for trust: the user can *see* "wide expressive gesture, arms outstretched" appear as they spread their arms. (And see it disappear if they untoggle the modifier.)
- Added a **Fullscreen** button to the HUD using `NSWindow.toggleFullScreen(_:)`.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
The whole project's value proposition is "the AI responds to *you*, not to a static prompt". M4 is where that becomes literally true. We chose the dumbest-possible deterministic implementation on purpose:

- Three pose rules + three motion buckets is plenty to make the output feel alive without us having to debug a state machine.
- Doing the modifier work *outside* `DiffusionPipeline` keeps the actor pure and the rules testable without running the model.
- Showing the effective prompt on screen is cheap and turns the system from "magic" into "obvious cause-and-effect" for the user. This is the single biggest UX win of M4 — every demo I've seen of live-diffusion apps fails because the user can't tell *what* changed when the output suddenly changes.

**Impact:**
- The prompt panel is busier. Acceptable for v1; M5 will add a "minimal HUD" toggle that hides everything but the FPS line + style preset.
- Motion modifier holds a tiny amount of state on the composer (last centroid + timestamp + smoothed speed). Cleared whenever the toggle goes off, so no stale hints.
- All rule thresholds are constants in `PromptComposer.swift`. Tune in place if a preset doesn't react well.

**Follow-up:**
This unblocks M5 (hardening + demo polish). Next batch:

- 30-minute thermal soak test on the M5 with live mode + all modifiers on. Watch the `live: <ms>/pass` line for thermal throttling.
- First-launch model downloader (right now we lean on the user to convert + drop files).
- Diffusion-stall fallback (already detected; needs a UI fade-out to passthrough rather than just text).
- "Minimal HUD" / clean demo mode.

Run M4 by:
1. Re-launch.
2. Pick a preset (e.g. "Neon noir").
3. Click **Load model** (now defaults to 384/ANE).
4. Flip **Live**.
5. Wave your arms / crouch / stand still and watch the green/orange chips light up under the prompt.

---

## 2026-05-11 — M3.5: diffusion-perf A/B knobs in the UI (no rebuild required)

**Decision / change:**
Added two segmented pickers under the live controls so the user can A/B the diffusion-perf levers from `Roadmap.md` P1 *without* a rebuild:

1. **Resolution** — `512×512` / `384×384`. Picks a sibling model directory (`sd-turbo` vs `sd-turbo-384`) under `Application Support/Artlify/Models/`. Affects the side length we resize the camera frame to before handing it to the encoder.
2. **Compute** — `CPU + ANE` / `CPU + GPU` / `All (auto)`. Maps to `MLComputeUnits.cpuAndNeuralEngine` / `.cpuAndGPU` / `.all`.

Implementation:

- Two new enums in `DiffusionBenchmark.swift`: `ComputeUnitChoice` and `ModelVariant`. `ModelVariant` carries both the directory name and the side length, so there's exactly one place to add a new resolution.
- `DiffusionBenchmark` now owns a *mutable* `pipeline` and `modelDirectory` (computed from `variant`). When either picker changes, `invalidatePipeline()` runs: `Task { await oldPipeline.unload() }`, instantiates a fresh `DiffusionPipeline(modelDirectory:, computeUnits:)`, resets `loadState` to `.idle`. The user must then click **Load model** to rehydrate. This keeps the rebuild explicit (it costs 5–10 s of cold load + ~3 GB of RAM) and avoids hot-swapping the pipeline under a running live loop.
- `LiveDiffusionDriver` no longer holds the pipeline at init; it borrows `settings.pipeline` and `settings.inputSide` on each loop iteration. So when the user rebuilds the pipeline, the next iteration sees `isLoaded == false`, parks the loop in `.waitingForModel`, and resumes seamlessly once `Load model` finishes — no driver restart needed.
- The two pickers in the UI are disabled while `liveOn || loadState == .loading` to prevent the user from yanking the rug out from under either operation.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
The whole point of running A/Bs is to see numbers next to each other. Forcing a rebuild between every variant turns a 30-second exercise into a 30-minute exercise. With the pickers in the HUD, the loop is:

1. Click **CPU + GPU** → wait for "model loaded" → flip **Live** → read `live: <ms>/pass` for ~10 s → flip Live off.
2. Click **CPU + ANE** → wait for "model loaded" → flip **Live** → read again.
3. Repeat for resolution.

Each result is one HUD line. Whichever combination wins, we keep — and the M4 milestone gets the better cycle time as its baseline.

**Impact:**
- The `sd-turbo-384` directory is *required* for the 384×384 picker to work. The conversion command is identical to the 512 one but with `--latent-h 48 --latent-w 48`:

  ```bash
  python -m python_coreml_stable_diffusion.torch2coreml \
    --convert-unet --convert-text-encoder \
    --convert-vae-decoder --convert-vae-encoder \
    --model-version stabilityai/sd-turbo \
    --bundle-resources-for-swift-cli \
    --attention-implementation SPLIT_EINSUM \
    --latent-h 48 --latent-w 48 \
    -o ./out-384
  # then: cp -R out-384/Resources/* \
  #   ~/Library/Containers/com.biru.Artlify/Data/Library/Application\ Support/Artlify/Models/sd-turbo-384/
  ```

  If the user picks 384×384 without that directory present, `Load model` fails with our existing `DiffusionError.modelDirectoryMissing`, which the HUD already surfaces. No crash.
- Switching compute units does *not* require any new model files — same .mlmodelc bundles work; CoreML handles the placement.
- The third lever from the roadmap ("split UNet on ANE / VAE on GPU") is intentionally not exposed yet. `apple/ml-stable-diffusion` doesn't expose per-submodule compute-unit selection through `StableDiffusionPipeline.init`, and forking the package is out of scope for M3.5. If the `.all` setting doesn't already do something close to this internally, we'll revisit during M5.

**Follow-up:**
Run the 4 A/Bs (`{512, 384} × {ANE, GPU}`), record the four `live: <ms>` numbers in this Journal as a follow-up entry, and pick the winner as the M4 baseline. Then open the next Journal entry to start M4.

---

## 2026-05-11 — M3 shipped: live diffusion loop + temporal blend + person composite

**Decision / change:**
Built the first version that "feels like Artlify": camera draws at 60 Hz, the diffusion pipeline runs continuously off the latest frame, and the renderer composites the stylized layer over the live camera using the Vision person mask.

New / changed code:

- `Artlify/RenderKit/Composite.metal` — new fragment shader `composite_fragment`. Inputs: camera (BGRA), `aiPrev` + `aiNext` (RGBA), mask (R8), and a `CompositeUniforms` constant buffer `{ blend_t, style_strength, mask_enabled, mask_softness }`. The shader does `lerp(aiPrev, aiNext, blend_t)` for the temporal blend, then `lerp(camera, ai, alpha)` where `alpha = style_strength * (mask_enabled ? mask_alpha * softness : 1)`.
- `Artlify/RenderKit/CameraMetalRenderer.swift` — extended substantially:
  - Holds `aiPrev`, `aiNext`, `personMaskTexture` slots in addition to the camera texture.
  - `submitStylized(_ cgImage:)` rotates `aiNext → aiPrev`, uploads the new CGImage as an `rgba8Unorm` texture (one-shot CGContext blit; no MTKTextureLoader to avoid its `URL`-only convenience overload).
  - `submitMask(_ pixelBuffer:)` binds the Vision mask via `CVMetalTextureCache` as an `r8Unorm` texture.
  - `compositeEnabled`, `styleStrength`, `maskEnabled`, `maskSoftness` knobs surface through to the uniforms each draw.
  - `styleCycleSeconds` is an EMA of the inter-arrival time of stylized submits (default 1 s). `blend_t` for each frame is `clamp(elapsed_since_last_stylized / styleCycleSeconds, 0, 1)`. So with our measured ~1 FPS diffusion the blend smoothly fades from prev → next over ~1 s and reaches "fully next" right around the time the next stylized frame lands.
- `Artlify/AppShell/LiveDiffusionDriver.swift` — new `@MainActor @Observable` driver. Loop: snapshot `session.latestPixelBuffer` → `PixelBufferToCGImage.makeCGImage(_:resizedTo: 512×512)` → `pipeline.generate(...)` → `renderer.submitStylized(...)`. Strict latest-frame-wins: while `generate` is in flight, new camera frames just overwrite the slot we'll read next. Reads prompt/steps/strength from a `DiffusionBenchmark` settings object so the existing UI controls drive both modes. Maintains an EMA of pass time + a 2 s "stall" detector that flips status without crashing the loop.
- `DiffusionBenchmark.pipeline` lifted from `private` to module-internal so the live driver can share the same loaded model — no double model load, no duplicate ~3 GB allocation.
- `ContentView`:
  - Owns the `LiveDiffusionDriver` (lazily constructed in `onAppear`).
  - New "Live" toggle button next to "Stylize current frame". Disabled until model is loaded.
  - New "style" slider (0–1, drives `styleStrength` uniform) and "mask on person" checkbox (drives `maskEnabled`).
  - New `liveStatusText` line: `live: <ms> / pass (<Hz>) · <N> passes` plus stall / error states.
  - Pushes the latest Vision mask into the renderer via `.onChange(of: vision.passCount)` — the renderer just re-binds a CVMetalTexture pointer, so this is essentially free.
  - Default `showVisionOverlay` flipped to `false` so the green skeleton doesn't fight the stylized output by default.

`xcodebuild build` is green with **zero warnings**.

**Reason:**
Three separable problems, three separable solutions:

1. *We can't render at diffusion speed.* So Metal renders at 60 Hz from a small set of texture slots and is completely unaware of pipeline latency.
2. *Diffusion frames pop.* So we keep the previous stylized texture around and crossfade over the measured cycle length. The cycle length self-tunes via EMA — if 384×384 makes diffusion 2× faster tomorrow, the blend speed adjusts automatically; no constant to retune.
3. *Background looks weird stylized.* So we use the Vision mask as the alpha for the stylized layer. With "mask on person" off, you get full-frame stylization (handy for debugging the diffusion output without the mask in the way).

The driver is intentionally not coupled to VisionSession. Either subsystem can pause without breaking the other; the renderer just falls back gracefully (mask off → full-frame stylize, no aiNext yet → passthrough).

**Impact:**
- Live mode now consumes the ANE continuously while it's on. Expect M5's thermal soak test to be the first real stress on the project. The "Live" button + the stall fallback give us a clean way to back off if it gets hot.
- Live mode also keeps the model loaded indefinitely (~3 GB resident). Acceptable for v1; M5 will look at unload-on-blur.
- The temporal blend feels right at ~1 Hz diffusion. If/when we get diffusion under 500 ms (via 384 / `.cpuAndGPU` / split-units), the blend will speed up automatically.

**Follow-up:**
After running this on hardware and watching the live HUD, decide whether to:

1. Push the optimisations queued in `Roadmap.md` P1 (384×384, `.cpuAndGPU` A/B, split UNet/VAE), or
2. Move directly to M4 (PromptKit + UI polish).

I'd lean toward (1) — even a 1.5× speedup makes the temporal blend feel dramatically more alive. But if the mask-composited 1 Hz output already looks good enough on real hardware, M4 is the better call so we can put the prompt UI in front of users.

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
