---
name: project-overview
description: Artlify macOS app — camera feed, Vision person segmentation/pose, Metal GPU particles, audio reactor, interactive game layer
metadata:
  type: project
---

macOS SwiftUI app (Artlify). Active branch: `universe-tune`. Architecture:
- CameraSession → CameraMetalView (passthrough + particle field + ASCII + trails)
- VisionSession → VisionProcessor (segmentation mask + body pose joints at ~15 Hz)
- AudioReactor: mic FFT → low/mid/high/level/transient published to particle shader
- BlobBoxesOverlay: neon tracker-box overlay per joint (strobe aesthetic)
- GameKit/: Universe Tune falling-tile game (Piano Tiles with body tracking)

**Why:** PBXFileSystemSynchronizedRootGroup — any new file dropped into Artlify/ folder is auto-included in the build target. No project.pbxproj edits needed.

**How to apply:** When adding new features, just create files in the right subfolder. SourceKit will show "Cannot find X in scope" false positives across new files until Xcode builds once.
