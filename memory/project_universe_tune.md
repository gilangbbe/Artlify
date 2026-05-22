
---
name: project-universe-tune
description: Universe Tune game — Piano Tiles using full body movement, Einaudi Experience melody, GameKit/ files
metadata:
  type: project
---

Piano Tiles game where the player uses their body (all Vision joints) to hit falling tiles that play Ludovico Einaudi's "Experience".

**Experience — correct key/tempo (confirmed via web research):**
- Key: **F# minor** (chord loop: F#m–A–C#m–D, i–III–v–VI)
- BPM: **92** (not 56; not G major)
- Lane notes: F#4(66) G#4(68) A4(69) B4(71) C#5(73) D5(74) E5(76) F#5(78)
- Melody: C#5→E5→F#5(half) / descent E5→C#5→A4 / C#m outline / D-chord peak F#5

**Files in `Artlify/GameKit/`:**
- `TileSong.swift` — 48-beat loop: Section A ostinato (F#m arpeg ×4), Section B melody, Section C climax
- `NotePlayer.swift` — AVAudioEngine + AVAudioUnitSampler (GM Grand Piano via macOS DLS) + LargeHall2 reverb
- `TileEngine.swift` — @Observable game loop at 60Hz; collision = any VisionJoint inside tile UV rect
- `UniverseTuneOverlay.swift` — Canvas with neon tile rectangles + corner brackets (BlobBoxes aesthetic) + score HUD

**Physics constants:** fallSpeed=0.22 UV/s, hitZoneY=0.72, tile visible for ~5.4s.

**Integration in ContentView.swift:** "universe tune" button in statusHUD; game timer at 60Hz feeds joints from vision.latestFrame; game overlay sits above particles/blobs layers; exit button top-right.

**Ghost note:** missed tiles play at velocity 28 so music doesn't stop on a miss.

**Why:** User wanted a full-body Piano Tiles experience as an interactive installation on the `universe-tune` branch.
