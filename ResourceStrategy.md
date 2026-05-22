# Artlify — Resources & Technical Strategy

---

## What "Resource Aware" Means Here

The app runs entirely on one chip — an M5 MacBook Pro. There is no separate graphics card. The CPU, GPU, AI engine, and memory are all shared on the same piece of silicon.

That means every feature competes for the same pool of resources. If the AI image generator is running, it takes time away from the particle system. If you load a bigger model, it eats into the memory budget for the camera and Metal renderer.

Being resource aware in this project means **knowing what each part of the app costs and keeping those costs from stepping on each other.**

---

## What the Resources Actually Are

### Time
The screen refreshes 60 times per second. That gives each frame about **16 milliseconds** to be drawn.

| What's happening | How often | How long it takes |
|---|---|---|
| Camera frame captured | 30× per second | < 5 ms |
| Person silhouette detected | 30× per second | 8–15 ms |
| Body pose detected | 15× per second | 5–10 ms |
| AI image generated | 3–6× per second | ~660 ms |
| Screen drawn (Metal) | 60× per second | < 8 ms |

The AI generation takes **660 milliseconds** — 40× longer than one screen frame. This is the central challenge the whole architecture is built around.

### Memory
The app shares **24 GB of unified memory** across everything running at once.

| What uses memory | How much |
|---|---|
| AI model (SD Turbo, fp16) | ~1.7 GB |
| Camera textures (GPU) | small, recycled |
| AI output textures (2 kept at a time) | small |
| Person mask texture | small |

The rule: never load the bigger model (SDXL, ~6 GB) while the main model is already loaded. They won't fit together with everything else running.

### Compute
Three processing units share the work:

- **ANE (Apple Neural Engine)** — runs the AI image generator
- **GPU** — draws everything on screen (Metal shaders, particles, effects)
- **CPU** — runs Vision (person detection), audio analysis, and app logic

They can work at the same time, but only if you route work to the right one.

---

## Technical Strategy

Three rules drive every decision in this project.

### Rule 1: No training, ever
The app only uses **pre-trained models** — models that someone else already trained and released. No datasets, no training machines, no ML expertise needed.

Models used:
- **Apple Vision** — built into macOS, free, detects people and body pose
- **SD Turbo** — open-source from Stability AI, converted to Apple's CoreML format

### Rule 2: Everything runs on-device
No cloud. No API keys. No internet required after the first model download. Everything runs locally on the Mac.

This means no latency from a server, no cost per frame, and no dependency on someone else's uptime.

### Rule 3: The frame budget is sacred
At 60 FPS, each frame has 16 ms to be drawn. The AI generator takes 660 ms — it can never finish in time for a single frame.

The solution: **treat the AI as a slow background worker, not a real-time renderer.**

```
AI generator  →  produces a new image every ~660 ms
Metal renderer →  draws 60 frames per second, smoothly blending
                  between the last two AI images while waiting for the next
```

This "temporal blend" is what makes a ~1.5 FPS AI feel like a living, fluid painting. The screen is always moving — the AI is just slowly updating the texture underneath.

---

## How the Architecture Enforces These Rules

**Drop, never queue.**
If the camera produces a frame and the AI is still busy, the frame is dropped — not stored in a buffer. This prevents a backlog from building up and the app falling further and further behind real time.

**One slot between every stage.**
Each handoff in the pipeline holds exactly one item: the latest. A slow stage misses frames; it never clogs the pipe.

**Six independent modules, no cross-imports.**
The app is split into small pieces (CaptureKit, VisionKit, DiffusionKit, RenderKit, etc.). They only talk to each other by passing simple values through streams. You can replace the AI model without touching the renderer. You can build the game layer (GameKit / universe-tune branch) without touching the diffusion layer at all.

**Graceful degradation.**
If the AI stalls for more than 2 seconds, the renderer falls back to camera + visual effects only. The user still sees a live, reactive image — just without AI stylization until it recovers.

---

## Where the Numbers Came From

All performance numbers were **measured on real hardware**, not guessed.

| Number | What it is | How it was found |
|---|---|---|
| 660 ms | AI pass at 384×384, CPU+ANE | Benchmarked in M1 milestone |
| 997 ms | AI pass at 512×512, ANE only | Same benchmark, rejected |
| < 150 ms | Continuity Camera end-to-end latency | Measured in M0 milestone |
| ~32 ms | Vision pass (seg + pose) | Measured in M2 milestone |

The original goal was ≥3 FPS for the AI layer. Reality was ~1.5 FPS. Rather than pretending otherwise, the architecture was designed from the start to tolerate a 2× miss on that number — and the temporal blend is what makes that acceptable.
