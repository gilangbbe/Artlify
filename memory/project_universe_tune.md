
---
name: project-universe-tune
description: Universe Tune game — Piano Tiles using full body movement, Einaudi Experience melody, GameKit/ files
metadata:
  type: project
---

Piano Tiles game where the player uses their body (all Vision joints) to hit falling tiles that play Ludovico Einaudi's "Experience" (56 BPM, G major, 4 lanes: G4/B4/D5/G5).

**Files created in `Artlify/GameKit/`:**
- `TileSong.swift` — 48-beat loop: Section A ostinato (G-B-D-B×4), Section B melody, Section C peak
- `NotePlayer.swift` — AVAudioEngine + AVAudioUnitSampler (GM Grand Piano via macOS DLS) + LargeHall2 reverb
- `TileEngine.swift` — @Observable game loop at 60Hz; collision = any VisionJoint inside tile UV rect
- `UniverseTuneOverlay.swift` — Canvas with neon tile rectangles + corner brackets (BlobBoxes aesthetic) + score HUD

**Physics constants:** fallSpeed=0.22 UV/s, hitZoneY=0.72, tile visible for ~5.4s.

**Integration in ContentView.swift:** "universe tune" button in statusHUD; game timer at 60Hz feeds joints from vision.latestFrame; game overlay sits above particles/blobs layers; exit button top-right.

**Ghost note:** missed tiles play at velocity 28 so music doesn't stop on a miss.

**Why:** User wanted a full-body Piano Tiles experience as an interactive installation on the `universe-tune` branch.
