//
//  VisionFrame.swift
//  Artlify / VisionKit
//
//  Output of one VisionProcessor pass. All coordinates are normalized
//  (0…1) in Vision's coordinate system: origin at bottom-left, x right,
//  y up. Callers that draw on top of the camera view need to flip y
//  and scale into view space.
//

import Foundation
import CoreVideo
import CoreGraphics

/// A single named joint with a normalized point + confidence.
nonisolated public struct VisionJoint: Sendable, Identifiable {
    public let id: String           // raw VNHumanBodyPoseObservation joint name
    public let point: CGPoint       // normalized (0…1), Vision-coordinates
    public let confidence: Float    // 0…1
    /// Which detected person this joint belongs to (0…N−1). Multiple
    /// people in frame each get a stable index for the lifetime of one
    /// VisionFrame; downstream consumers can namespace per-person state
    /// (e.g. blob tracking) with this without doing the matching
    /// themselves.
    public let personIndex: Int

    nonisolated public init(id: String,
                            point: CGPoint,
                            confidence: Float,
                            personIndex: Int = 0) {
        self.id = id
        self.point = point
        self.confidence = confidence
        self.personIndex = personIndex
    }
}

nonisolated public struct VisionFrame: @unchecked Sendable {
    /// Person-segmentation mask, single-channel (kCVPixelFormatType_OneComponent8).
    /// May be nil if segmentation failed or no person was found.
    public let personMask: CVPixelBuffer?
    /// Detected body-pose joints (normalized). Empty if no person found.
    public let joints: [VisionJoint]
    /// Detected open-hand summary (most-open hand in frame). nil when
    /// no hand crosses the openness threshold or hand-pose detection
    /// is disabled.
    public let handOpen: HandOpenInfo?
    /// Wall-clock seconds for the full processing pass (seg + pose).
    public let processingSeconds: Double
    /// Source frame width/height in pixels (used by overlay code to
    /// translate normalized joint coords back into the camera frame).
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// Monotonic timestamp when processing finished.
    public let timestamp: CFAbsoluteTime

    nonisolated public init(personMask: CVPixelBuffer?,
                joints: [VisionJoint],
                handOpen: HandOpenInfo? = nil,
                processingSeconds: Double,
                sourceWidth: Int,
                sourceHeight: Int,
                timestamp: CFAbsoluteTime) {
        self.personMask = personMask
        self.joints = joints
        self.handOpen = handOpen
        self.processingSeconds = processingSeconds
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.timestamp = timestamp
    }
}
