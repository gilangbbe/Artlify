//
//  PoseOverlay.swift
//  Artlify / AppShell
//
//  Lightweight SwiftUI Canvas overlay that draws Vision body-pose
//  joints + a wireframe skeleton on top of the camera view. Purely
//  diagnostic — the real renderer (M3) will compose the segmentation
//  mask in Metal.
//
//  Coordinate system note: Vision returns normalized (0…1) points in
//  bottom-left origin; SwiftUI's local coordinate space is top-left.
//  We flip Y here.
//

import SwiftUI

struct PoseOverlay: View {
    let frame: VisionFrame?
    let viewSize: CGSize

    // Skeleton edges as pairs of VNHumanBodyPoseObservation joint raw names.
    // Kept as static plain strings to avoid pulling Vision into this file.
    private static let bones: [(String, String)] = [
        // head
        ("nose", "left_eye_joint"), ("nose", "right_eye_joint"),
        ("left_eye_joint", "left_ear_joint"), ("right_eye_joint", "right_ear_joint"),
        // torso
        ("left_shoulder_1_joint", "right_shoulder_1_joint"),
        ("left_shoulder_1_joint", "left_hip_joint"),
        ("right_shoulder_1_joint", "right_hip_joint"),
        ("left_hip_joint", "right_hip_joint"),
        // arms
        ("left_shoulder_1_joint", "left_forearm_joint"),
        ("left_forearm_joint", "left_hand_joint"),
        ("right_shoulder_1_joint", "right_forearm_joint"),
        ("right_forearm_joint", "right_hand_joint"),
        // legs
        ("left_hip_joint", "left_leg_joint"),
        ("left_leg_joint", "left_foot_joint"),
        ("right_hip_joint", "right_leg_joint"),
        ("right_leg_joint", "right_foot_joint"),
    ]

    var body: some View {
        Canvas { ctx, size in
            guard let frame, !frame.joints.isEmpty else { return }

            // Build a lookup once per draw.
            let byName: [String: VisionJoint] = Dictionary(
                uniqueKeysWithValues: frame.joints.map { ($0.id, $0) }
            )

            // Vision returns normalized coords. We map them to the actual
            // visible camera-frame rect within `size`. The Metal renderer
            // does aspect-fill, so we replicate that here: scale uniformly
            // by max(scaleX, scaleY) and center.
            let srcAspect = CGFloat(frame.sourceWidth) / CGFloat(frame.sourceHeight)
            let viewAspect = size.width / size.height
            let drawW: CGFloat
            let drawH: CGFloat
            if srcAspect > viewAspect {
                // Source wider — height fills, width overflows.
                drawH = size.height
                drawW = drawH * srcAspect
            } else {
                drawW = size.width
                drawH = drawW / srcAspect
            }
            let offsetX = (size.width - drawW) / 2.0
            let offsetY = (size.height - drawH) / 2.0

            func project(_ p: CGPoint) -> CGPoint {
                // Vision: bottom-left origin, y up. SwiftUI: top-left.
                CGPoint(
                    x: offsetX + p.x * drawW,
                    y: offsetY + (1.0 - p.y) * drawH
                )
            }

            // Bones first.
            var bonePath = Path()
            for (a, b) in Self.bones {
                guard
                    let ja = byName[a], let jb = byName[b],
                    ja.confidence >= 0.3, jb.confidence >= 0.3
                else { continue }
                bonePath.move(to: project(ja.point))
                bonePath.addLine(to: project(jb.point))
            }
            ctx.stroke(
                bonePath,
                with: .color(.green.opacity(0.85)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )

            // Then joint dots.
            for joint in frame.joints where joint.confidence >= 0.3 {
                let p = project(joint.point)
                let r: CGFloat = 4
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.yellow))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }
}
