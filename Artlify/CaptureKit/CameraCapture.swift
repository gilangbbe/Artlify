//
//  CameraCapture.swift
//  Artlify / CaptureKit
//
//  Wraps AVCaptureSession and exposes the latest video frame as an
//  AsyncStream<CVPixelBuffer>. Designed for "latest-frame-wins":
//  the stream uses .bufferingNewest(1) so slow consumers never cause
//  buffer build-up — they simply skip frames.
//
//  Continuity Camera is preferred when available; otherwise the system
//  default video device is used.
//

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog

public enum CameraCaptureError: Error, LocalizedError {
    case noVideoDevice
    case cannotAddInput
    case cannotAddOutput
    case sessionConfigurationFailed
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .noVideoDevice: return "No video capture device was found."
        case .cannotAddInput: return "Capture session refused the camera input."
        case .cannotAddOutput: return "Capture session refused the video output."
        case .sessionConfigurationFailed: return "Capture session configuration failed."
        case .notAuthorized: return "Camera access was denied."
        }
    }
}

public struct CameraDeviceInfo: Sendable, Identifiable, Hashable {
    public let id: String          // AVCaptureDevice.uniqueID
    public let localizedName: String
    public let isContinuityCamera: Bool
}

/// Thread-safe camera capture. All AVFoundation work happens on a private serial queue.
/// The class is `nonisolated` (the project defaults to MainActor isolation) so that
/// AVCaptureVideoDataOutput's delegate callback — which runs on a background queue —
/// can touch internal state without crossing actor boundaries.
nonisolated public final class CameraCapture: NSObject, @unchecked Sendable {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "CameraCapture")
    private let sessionQueue = DispatchQueue(label: "com.biru.Artlify.CameraCapture.session")
    private let sampleQueue  = DispatchQueue(label: "com.biru.Artlify.CameraCapture.samples")

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var preferContinuityCamera = true

    /// Latest-frame continuation. Replaced when `frames()` is called again.
    private var continuation: AsyncStream<CVPixelBuffer>.Continuation?

    public override init() {
        super.init()
        // Observe device-connection notifications so that a Continuity Camera
        // appearing after the session has already started (the common case on
        // second launch — the iPhone hasn't been activated yet) automatically
        // becomes the active input.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceConnected(_:)),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceDisconnected(_:)),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Async stream of pixel buffers. Buffers older than the most recent are dropped.
    /// Calling this a second time replaces the previous stream.
    public func frames() -> AsyncStream<CVPixelBuffer> {
        AsyncStream<CVPixelBuffer>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.sessionQueue.async {
                self.continuation?.finish()
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.sessionQueue.async {
                    self?.continuation = nil
                }
            }
        }
    }

    /// Discover candidate capture devices. Continuity Camera is listed first when present.
    public static func availableDevices() -> [CameraDeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [
            .continuityCamera,
            .external,
            .builtInWideAngleCamera,
            .deskViewCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map {
            CameraDeviceInfo(
                id: $0.uniqueID,
                localizedName: $0.localizedName,
                isContinuityCamera: $0.deviceType == .continuityCamera
            )
        }
    }

    /// Request camera authorization, prompting the user if needed.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Start the session, optionally targeting a specific device by uniqueID.
    /// Falls back to: Continuity Camera → first external → built-in wide angle.
    public func start(preferredDeviceID: String? = nil) async throws {
        guard await requestAuthorization() else {
            throw CameraCaptureError.notAuthorized
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureLocked(preferredDeviceID: preferredDeviceID)
                    if !self.session.isRunning { self.session.startRunning() }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    /// Force a re-pick of the camera. Useful when the user manually plugs in
    /// the iPhone after launch and wants to switch to it.
    public func reconnect(preferredDeviceID: String? = nil) {
        sessionQueue.async {
            do {
                try self.configureLocked(preferredDeviceID: preferredDeviceID)
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                self.log.error("reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Name of the currently active capture device, if any. Safe to call from any thread.
    public var currentDeviceName: String? {
        sessionQueue.sync { currentInput?.device.localizedName }
    }

    // MARK: - Notifications

    @objc private func handleDeviceConnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }
        log.info("Device connected: \(device.localizedName, privacy: .public) [\(device.deviceType.rawValue, privacy: .public)]")

        // If a Continuity Camera shows up and we are currently using something else,
        // auto-switch to it. This is the fix for "iPhone only connects on first launch".
        sessionQueue.async {
            guard self.preferContinuityCamera,
                  device.deviceType == .continuityCamera,
                  self.currentInput?.device.deviceType != .continuityCamera else { return }
            do {
                try self.configureLocked(preferredDeviceID: device.uniqueID)
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                self.log.error("auto-switch to Continuity Camera failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        log.info("Device disconnected: \(device.localizedName, privacy: .public)")
        sessionQueue.async {
            // If our active device went away, fall back to whatever is left.
            guard self.currentInput?.device.uniqueID == device.uniqueID else { return }
            do {
                try self.configureLocked(preferredDeviceID: nil)
            } catch {
                self.log.error("fallback after disconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private

    private func configureLocked(preferredDeviceID: String?) throws {
        guard let device = pickDevice(preferredID: preferredDeviceID) else {
            throw CameraCaptureError.noVideoDevice
        }
        log.info("Using camera: \(device.localizedName, privacy: .public) (\(device.deviceType.rawValue, privacy: .public))")

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        if let existing = currentInput {
            session.removeInput(existing)
            currentInput = nil
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraCaptureError.cannotAddInput
        }
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotAddInput
        }
        session.addInput(input)
        currentInput = input

        // Cap the device's delivered frame rate so the CMIO extension
        // upstream of `AVCaptureVideoDataOutput` doesn't queue more
        // frames than we can drain. iPhone Continuity Camera defaults
        // to a much higher rate (up to 60 fps) than our compositor +
        // Vision + SwiftUI overlays can consume, which manifests as
        // `CMIO_DAL_CMIOExtension_Stream.mm:ReceivedSampleBuffer N queue full`
        // in Console + matching FPS drops. 30 fps is the documented
        // Continuity sweet spot and matches our render budget.
        //
        // `alwaysDiscardsLateVideoFrames` only drops frames AFTER they
        // enter our process; it doesn't relieve the driver-side queue.
        // Capping `activeVideoMin/MaxFrameDuration` is the only way to
        // tell the camera daemon "don't bother".
        do {
            try device.lockForConfiguration()
            let target = CMTime(value: 1, timescale: 30)
            // Some devices (e.g. Continuity) refuse arbitrary durations
            // — clamp to the nearest supported range on the active
            // format so the assignment can't throw a range exception.
            if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
                let minDur = range.minFrameDuration
                let maxDur = range.maxFrameDuration
                let clamped = CMTimeMaximum(CMTimeMinimum(target, maxDur), minDur)
                device.activeVideoMinFrameDuration = clamped
                device.activeVideoMaxFrameDuration = clamped
            } else {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            device.unlockForConfiguration()
        } catch {
            log.error("frame-rate cap failed: \(error.localizedDescription, privacy: .public)")
        }

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                throw CameraCaptureError.cannotAddOutput
            }
            session.addOutput(output)
        }
    }

    private func pickDevice(preferredID: String?) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [
            .continuityCamera, .external, .builtInWideAngleCamera, .deskViewCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        if let id = preferredID,
           let match = discovery.devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        if let cc = discovery.devices.first(where: { $0.deviceType == .continuityCamera }) {
            return cc
        }
        return discovery.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }
}

nonisolated extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Yield to the latest-frame stream. AsyncStream's .bufferingNewest(1)
        // policy guarantees a single-slot buffer (no growth under backpressure).
        continuation?.yield(pb)
    }
}
