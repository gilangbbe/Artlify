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

    public init(segmentationQuality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = segmentationQuality
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = seg
        self.poseRequest = VNDetectHumanBodyPoseRequest()
    }

    /// Run segmentation + pose on a single pixel buffer.
    public func process(_ pixelBuffer: CVPixelBuffer) throws -> VisionFrame {
        let t0 = CFAbsoluteTimeGetCurrent()

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([segmentationRequest, poseRequest])

        // ---- Segmentation
        let mask = (segmentationRequest.results?.first as? VNPixelBufferObservation)?.pixelBuffer

        // ---- Pose
        var joints: [VisionJoint] = []
        if let observation = poseRequest.results?.first {
            // Pull every recognized joint above a small confidence floor.
            let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
            joints.reserveCapacity(recognized.count)
            for (jointName, point) in recognized where point.confidence >= 0.2 {
                joints.append(
                    VisionJoint(
                        id: jointName.rawValue.rawValue,
                        point: point.location,
                        confidence: point.confidence
                    )
                )
            }
        }

        let dt = CFAbsoluteTimeGetCurrent() - t0
        let frame = VisionFrame(
            personMask: mask,
            joints: joints,
            processingSeconds: dt,
            sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
            sourceHeight: CVPixelBufferGetHeight(pixelBuffer),
            timestamp: CFAbsoluteTimeGetCurrent()
        )
        return frame
    }
}
