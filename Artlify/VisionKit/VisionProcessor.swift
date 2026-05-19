//
//  VisionProcessor.swift
//  Artlify / VisionKit
//
//  Wraps Vision's person-segmentation and body-pose requests behind a
//  Swift actor. One CVPixelBuffer in → one VisionFrame out.
//
//  Design choices (see ProjectDocument.md §4 / §6):
//    * `.balanced` segmentation quality is the documented sweet spot
//      for live use on Apple Silicon: ~3× faster than .accurate, far
//      cleaner edges than .fast. We trade ~1 ms of latency for a
//      noticeably crisper alpha matte at a person's hairline.
//    * Single VNDetectHumanBodyPoseRequest — we only care about one
//      person on screen for v1.
//    * Both requests run inside a single `VNImageRequestHandler.perform`
//      call so they share image-decoding work.
//    * The actor gates re-entrancy: callers can fire `process(_:)`
//      whenever they want; if one is already in flight, the second
//      `await` simply waits. With our latest-frame-wins polling driver
//      (VisionSession) this collapses to "drop intermediate frames",
//      which is exactly what we want.
//

import Foundation
@preconcurrency import Vision
import CoreVideo
import OSLog

public actor VisionProcessor {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "VisionKit")

    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private let poseRequest: VNDetectHumanBodyPoseRequest
    private let handRequest: VNDetectHumanHandPoseRequest

    /// Toggleable hand-pose detection. Off by default — the request
    /// adds measurable cost on top of segmentation + body pose, and
    /// most installation modes don't need it. Flip on when the
    /// "hand frame" gesture is active.
    public var handPoseEnabled: Bool = false

    public init(segmentationQuality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = segmentationQuality
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = seg
        self.poseRequest = VNDetectHumanBodyPoseRequest()
        let hand = VNDetectHumanHandPoseRequest()
        hand.maximumHandCount = 2
        self.handRequest = hand
    }

    /// Enable/disable hand-pose detection at runtime. Cheap; just
    /// toggles whether the request is included in the next `perform`.
    public func setHandPoseEnabled(_ enabled: Bool) {
        handPoseEnabled = enabled
    }

    /// Run segmentation + pose on a single pixel buffer.
    public func process(_ pixelBuffer: CVPixelBuffer) throws -> VisionFrame {
        let t0 = CFAbsoluteTimeGetCurrent()

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        var requests: [VNRequest] = [segmentationRequest, poseRequest]
        if handPoseEnabled { requests.append(handRequest) }
        try handler.perform(requests)

        // ---- Segmentation
        let mask = (segmentationRequest.results?.first as? VNPixelBufferObservation)?.pixelBuffer

        // ---- Pose (multi-person). Vision returns one observation per
        // detected body; we tag every joint with its observation index
        // so downstream consumers can namespace per-person state. Cap
        // at 4 bodies — enough for a small group in front of a single
        // installation camera, low enough to keep per-frame cost bounded.
        var joints: [VisionJoint] = []
        let bodies = (poseRequest.results ?? []).prefix(4)
        for (idx, observation) in bodies.enumerated() {
            let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
            joints.reserveCapacity(joints.count + recognized.count)
            for (jointName, point) in recognized where point.confidence >= 0.2 {
                joints.append(
                    VisionJoint(
                        id: jointName.rawValue.rawValue,
                        point: point.location,
                        confidence: point.confidence,
                        personIndex: idx
                    )
                )
            }
        }

        // ---- Hand pose → open-hand detection
        var handOpen: HandOpenInfo? = nil
        if handPoseEnabled, let hands = handRequest.results, !hands.isEmpty {
            // Up to 2 hands; the detector picks the most-open.
            let obs = hands
                .sorted { $0.confidence > $1.confidence }
                .prefix(2)
                .map { Self.makeObservation(from: $0) }
            handOpen = HandOpenDetector.detect(Array(obs))
        }

        let dt = CFAbsoluteTimeGetCurrent() - t0
        let frame = VisionFrame(
            personMask: mask,
            joints: joints,
            handOpen: handOpen,
            processingSeconds: dt,
            sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
            sourceHeight: CVPixelBufferGetHeight(pixelBuffer),
            timestamp: CFAbsoluteTimeGetCurrent()
        )
        return frame
    }

    /// Pull the wrist + 4 fingertips + 4 MCPs we need from a Vision
    /// hand-pose observation, with chirality and a mean confidence.
    private static func makeObservation(
        from o: VNHumanHandPoseObservation
    ) -> HandObservation {
        let chirality: HandObservation.Chirality
        switch o.chirality {
        case .left:    chirality = .left
        case .right:   chirality = .right
        case .unknown: chirality = .unknown
        @unknown default: chirality = .unknown
        }

        func pick(_ name: VNHumanHandPoseObservation.JointName,
                  minConf: Float = 0.3) -> (CGPoint?, Float) {
            guard let p = try? o.recognizedPoint(name),
                  p.confidence >= minConf
            else { return (nil, 0) }
            return (p.location, p.confidence)
        }

        let (wrist, cW) = pick(.wrist)
        let tipNames: [VNHumanHandPoseObservation.JointName] =
            [.indexTip, .middleTip, .ringTip, .littleTip]
        let mcpNames: [VNHumanHandPoseObservation.JointName] =
            [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        var tips: [CGPoint?] = []
        var mcps: [CGPoint?] = []
        var confs: [Float] = [cW].filter { $0 > 0 }
        for n in tipNames {
            let (p, c) = pick(n)
            tips.append(p)
            if c > 0 { confs.append(c) }
        }
        for n in mcpNames {
            let (p, c) = pick(n)
            mcps.append(p)
            if c > 0 { confs.append(c) }
        }

        let mean = confs.isEmpty
            ? 0
            : confs.reduce(0, +) / Float(confs.count)

        return HandObservation(
            chirality: chirality,
            wrist: wrist,
            tips: tips,
            mcps: mcps,
            confidence: mean
        )
    }
}
