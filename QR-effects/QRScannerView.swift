//
//  QRScannerView.swift
//  QR-effects
//
//  Created by k zhukovskaya on 25.05.2026.
//

import AVFoundation
import CoreImage
import Vision
import SwiftUI
import UIKit

struct QRScannerView: UIViewRepresentable {
    @Binding var isDetected: Bool
    @Binding var scannedCode: String?
    @Binding var quad: QRQuad?
    var debugInfo: Binding<QRDebugInfo?>? = nil
    @Binding var scanningEnabled: Bool
    @Binding var resetCounter: Int
    var detectionHoldSeconds: TimeInterval = 0.8

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.videoGravity = .resizeAspectFill

        context.coordinator.attach(to: view.videoPreviewLayer)
        context.coordinator.start()

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCode = { code in
            scannedCode = code
            isDetected = true
        }
        context.coordinator.detectionHoldSeconds = detectionHoldSeconds
        context.coordinator.onDetectState = { detected in
            isDetected = detected
        }
        context.coordinator.onQuad = { newQuad in
            quad = newQuad
        }
        context.coordinator.onDebug = { info in
            debugInfo?.wrappedValue = info
        }

        context.coordinator.detectionHoldSeconds = detectionHoldSeconds
        context.coordinator.applyResetIfNeeded(resetCounter)
        context.coordinator.setScanningEnabled(scanningEnabled)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let metadataOutput = AVCaptureMetadataOutput()
        private let videoOutput = AVCaptureVideoDataOutput()
        private let sessionQueue = DispatchQueue(label: "qr.effects.session")
        private let visionQueue = DispatchQueue(label: "qr.effects.vision", qos: .userInitiated)

        var onCode: ((String) -> Void)?
        var onDetectState: ((Bool) -> Void)?
        var onQuad: ((QRQuad?) -> Void)?
        var onDebug: ((QRDebugInfo?) -> Void)?
        var detectionHoldSeconds: TimeInterval = 0.8
        private var scanningEnabled = true
        private var lastResetCounter: Int = 0

        private var lastDetectAt: Date?
        private var clearWorkItem: DispatchWorkItem?
        private var lastQuad: QRQuad?
        private var lastDeviceQuad: [CGPoint]?
        private var lostFrames = 0
        private let holdFrames = 10

        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private var lastVisionAt: CFTimeInterval = 0
        private let visionMinInterval: CFTimeInterval = 0.12 // ~8 fps for fallback

        private weak var previewLayer: AVCaptureVideoPreviewLayer?

        func attach(to previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            previewLayer.session = session
        }

        func setScanningEnabled(_ enabled: Bool) {
            guard enabled != scanningEnabled else { return }
            scanningEnabled = enabled
            if enabled {
                start()
            } else {
                stop()
            }
        }

        func applyResetIfNeeded(_ counter: Int) {
            guard counter != lastResetCounter else { return }
            lastResetCounter = counter
            resetState()
        }

        func start() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                switch status {
                case .authorized:
                    self.configureIfNeeded()
                    self.session.startRunning()
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        guard granted else { return }
                        self.sessionQueue.async {
                            self.configureIfNeeded()
                            self.session.startRunning()
                        }
                    }
                default:
                    break
                }
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        private func resetState() {
            clearWorkItem?.cancel()
            lastDetectAt = nil
            lastQuad = nil
            lastDeviceQuad = nil
            lostFrames = 0
            DispatchQueue.main.async {
                self.onDetectState?(false)
                self.onQuad?(nil)
                self.onDebug?(nil)
            }
        }

        private func configureIfNeeded() {
            guard session.inputs.isEmpty else { return }

            session.beginConfiguration()
            session.sessionPreset = .high

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            if device.isFocusModeSupported(.continuousAutoFocus) || device.isExposureModeSupported(.continuousAutoExposure) {
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    if device.isLowLightBoostSupported {
                        device.automaticallyEnablesLowLightBoostWhenAvailable = true
                    }
                    device.unlockForConfiguration()
                } catch {
                    // ignore
                }
            }
            session.addInput(input)

            guard session.canAddOutput(metadataOutput) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(metadataOutput)

            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            }

            // Fallback detector on raw frames (Vision + preprocessing)
            if session.canAddOutput(videoOutput) {
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
                session.addOutput(videoOutput)
            }

            session.commitConfiguration()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard scanningEnabled else { return }
            for obj in metadataObjects {
                guard let readable = obj as? AVMetadataMachineReadableCodeObject,
                      readable.type == .qr,
                      let value = readable.stringValue,
                      !value.isEmpty
                else { continue }
                lastDetectAt = Date()
                onDetectState?(true)
                onCode?(value)
                scheduleClearIfNeeded()
                break
            }
        }

        private func acceptQuad(_ quad: QRQuad, confidence: CGFloat) {
            let alpha: CGFloat = 0.25
            let smoothed: QRQuad
            if let prev = lastQuad {
                let maxJump = maxPointDelta(prev: prev, next: quad)
                if maxJump > 0.12 {
                    smoothed = quad
                } else {
                smoothed = QRQuad(
                    topLeft: ema(prev.topLeft, quad.topLeft, alpha: alpha),
                    topRight: ema(prev.topRight, quad.topRight, alpha: alpha),
                    bottomRight: ema(prev.bottomRight, quad.bottomRight, alpha: alpha),
                    bottomLeft: ema(prev.bottomLeft, quad.bottomLeft, alpha: alpha),
                    confidence: confidence,
                    opacity: 1
                )
                }
            } else {
                smoothed = quad
            }
            lastQuad = smoothed
            lostFrames = 0
            DispatchQueue.main.async { [smoothed] in
                self.onQuad?(smoothed)
            }
        }

        private func maxPointDelta(prev: QRQuad, next: QRQuad) -> CGFloat {
            let ds: [CGFloat] = [
                hypot(prev.topLeft.x - next.topLeft.x, prev.topLeft.y - next.topLeft.y),
                hypot(prev.topRight.x - next.topRight.x, prev.topRight.y - next.topRight.y),
                hypot(prev.bottomRight.x - next.bottomRight.x, prev.bottomRight.y - next.bottomRight.y),
                hypot(prev.bottomLeft.x - next.bottomLeft.x, prev.bottomLeft.y - next.bottomLeft.y),
            ]
            return ds.max() ?? 0
        }

        private func handleLost() {
            guard let lastQuad else {
                DispatchQueue.main.async { self.onQuad?(nil) }
                return
            }

            lostFrames += 1
            if lostFrames <= holdFrames {
                let fade = 1 - (CGFloat(lostFrames) / CGFloat(holdFrames))
                let faded = QRQuad(
                    topLeft: lastQuad.topLeft,
                    topRight: lastQuad.topRight,
                    bottomRight: lastQuad.bottomRight,
                    bottomLeft: lastQuad.bottomLeft,
                    confidence: lastQuad.confidence,
                    opacity: max(0, fade)
                )
                DispatchQueue.main.async { self.onQuad?(faded) }
            } else {
                self.lastQuad = nil
                DispatchQueue.main.async { self.onQuad?(nil) }
            }
        }

        private func scheduleClearIfNeeded() {
            clearWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(self.lastDetectAt ?? .distantPast)
                if elapsed >= self.detectionHoldSeconds {
                    self.onDetectState?(false)
                    self.handleLost()
                } else {
                    self.scheduleClearIfNeeded()
                }
            }
            clearWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + detectionHoldSeconds, execute: item)
        }
    }
}

// MARK: - Vision fallback

extension QRScannerView.Coordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    private struct CandidateFrame {
        let image: CIImage
        let roiInFull: CGRect
        let fullExtent: CGRect
        let tag: String
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard scanningEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastVisionAt >= visionMinInterval else { return }
        lastVisionAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let candidates = preprocessFrame(ciImage, lastDeviceQuad: lastDeviceQuad)

        for candidate in candidates {
            if let obs = detectQRCandidates(candidate.image).first, obs.confidence >= 0.35 {
                let visionPts = barcodePoints(from: obs) // normalized, origin bottom-left, relative to candidate.image
                let devicePts = mapCandidateVisionPointsToDevice(visionPts, candidate: candidate)
                let orderedDevice = orderPoints(devicePts)

                if let quad = mapCameraPointsToPreview(devicePoints: orderedDevice, confidence: CGFloat(obs.confidence)) {
                    DispatchQueue.main.async {
                        self.onDetectState?(true)
                    }
                    lastDetectAt = Date()
                    self.lastDeviceQuad = orderedDevice
                    acceptQuad(quad, confidence: CGFloat(obs.confidence))

#if DEBUG
                    publishDebug(rawVisionPoints: visionPts, devicePoints: orderedDevice, candidate: candidate, previewLayer: previewLayer)
#endif

                    if let payload = obs.payloadStringValue, !payload.isEmpty {
                        DispatchQueue.main.async {
                            self.onCode?(payload)
                        }
                    } else {
                        // Fallback decode on perspective-corrected QR plane.
                        if let warped = warpQR(ciImage, devicePoints: orderedDevice),
                           let decoded = decodeQR(warped),
                           !decoded.isEmpty {
                            DispatchQueue.main.async {
                                self.onCode?(decoded)
                            }
                        }
                    }
                    DispatchQueue.main.async { self.scheduleClearIfNeeded() }
                    return
                }
            }
        }

        // No detection on this frame; keep mask via hold logic.
        DispatchQueue.main.async { self.handleLost() }
    }

    private func preprocessFrame(_ frame: CIImage, lastDeviceQuad: [CGPoint]?) -> [CandidateFrame] {
        var out: [CandidateFrame] = []
        let full = frame.extent
        let roi: CGRect
        if let lastDeviceQuad, lastDeviceQuad.count == 4 {
            roi = roiRect(forDevicePoints: lastDeviceQuad, extent: full, padding: 0.25)
        } else {
            roi = full
        }

        let base = frame.cropped(to: roi)
        out.append(CandidateFrame(image: base, roiInFull: roi, fullExtent: full, tag: "base"))

        // grayscale + contrast
        if let mono = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: base,
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.35,
        ])?.outputImage {
            out.append(CandidateFrame(image: mono, roiInFull: roi, fullExtent: full, tag: "mono"))
        }

        // sharpen
        if let sharp = CIFilter(name: "CISharpenLuminance", parameters: [
            kCIInputImageKey: base,
            kCIInputSharpnessKey: 0.55,
        ])?.outputImage {
            out.append(CandidateFrame(image: sharp, roiInFull: roi, fullExtent: full, tag: "sharp"))
        }

        // threshold (if available)
        if let otsu = CIFilter(name: "CIColorThresholdOtsu", parameters: [kCIInputImageKey: base])?.outputImage {
            out.append(CandidateFrame(image: otsu, roiInFull: roi, fullExtent: full, tag: "otsu"))
        }

        // upscale for tiny QR
        if min(base.extent.width, base.extent.height) > 0,
           let up = CIFilter(name: "CILanczosScaleTransform", parameters: [
                kCIInputImageKey: base,
                kCIInputScaleKey: 1.6,
                kCIInputAspectRatioKey: 1.0,
           ])?.outputImage {
            out.append(CandidateFrame(image: up, roiInFull: roi, fullExtent: full, tag: "upscale"))
        }

        return out
    }

    private func detectQRCandidates(_ frame: CIImage) -> [VNBarcodeObservation] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        request.preferBackgroundProcessing = true

        let handler = VNImageRequestHandler(ciImage: frame, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return (request.results as? [VNBarcodeObservation]) ?? []
        } catch {
            return []
        }
    }

    private func warpQR(_ frame: CIImage, devicePoints: [CGPoint]) -> CIImage? {
        // devicePoints are normalized (0..1) with origin top-left.
        guard devicePoints.count == 4 else { return nil }
        let ordered = orderPoints(devicePoints)

        let extent = frame.extent
        func toCI(_ p: CGPoint) -> CGPoint {
            // CIImage coords: origin bottom-left.
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }

        let tl = toCI(ordered[0])
        let tr = toCI(ordered[1])
        let br = toCI(ordered[2])
        let bl = toCI(ordered[3])

        guard let corrected = CIFilter(name: "CIPerspectiveCorrection", parameters: [
            kCIInputImageKey: frame,
            "inputTopLeft": CIVector(cgPoint: tl),
            "inputTopRight": CIVector(cgPoint: tr),
            "inputBottomRight": CIVector(cgPoint: br),
            "inputBottomLeft": CIVector(cgPoint: bl),
        ])?.outputImage else {
            return nil
        }

        // Normalize output size (square) for easier decoding.
        let target = 520.0
        let sx = target / max(1, corrected.extent.width)
        let sy = target / max(1, corrected.extent.height)
        let s = min(sx, sy)
        return corrected.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    private func decodeQR(_ image: CIImage) -> String? {
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            let res = (request.results as? [VNBarcodeObservation]) ?? []
            return res.first?.payloadStringValue
        } catch {
            return nil
        }
    }

    private func barcodePoints(from obs: VNBarcodeObservation) -> [CGPoint] {
        // In many SDKs VNBarcodeObservation does not expose `cornerPoints`,
        // but it does expose 4 corners like VNRectangleObservation.
        [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft]
    }

    private func mapCandidateVisionPointsToDevice(_ visionPoints: [CGPoint], candidate: CandidateFrame) -> [CGPoint] {
        // visionPoints: normalized to candidate.image, origin bottom-left.
        // Map back into full-image normalized (origin bottom-left), then to device (origin top-left).
        let fullW = candidate.fullExtent.width
        let fullH = candidate.fullExtent.height
        let roi = candidate.roiInFull
        let roiOffsetX = roi.minX - candidate.fullExtent.minX
        let roiOffsetY = roi.minY - candidate.fullExtent.minY

        return visionPoints.map { p in
            let xFull = (roiOffsetX + p.x * roi.width) / max(1, fullW)
            let yFull = (roiOffsetY + p.y * roi.height) / max(1, fullH)
            return CGPoint(x: xFull, y: 1 - yFull) // device coords (top-left origin)
        }
    }

    private func mapCameraPointsToPreview(devicePoints: [CGPoint], confidence: CGFloat) -> QRQuad? {
        guard let previewLayer else { return nil }
        let layerSize = previewLayer.bounds.size
        guard layerSize.width > 0, layerSize.height > 0 else { return nil }

        let layerPts = devicePoints.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
        let normalized = layerPts.map { CGPoint(x: $0.x / layerSize.width, y: $0.y / layerSize.height) }

        return QRQuad(
            topLeft: normalized[0],
            topRight: normalized[1],
            bottomRight: normalized[2],
            bottomLeft: normalized[3],
            confidence: confidence,
            opacity: 1
        )
    }

    private func roiRect(forDevicePoints pts: [CGPoint], extent: CGRect, padding: CGFloat) -> CGRect {
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let minX = max(0, (xs.min() ?? 0))
        let maxX = min(1, (xs.max() ?? 1))
        let minY = max(0, (ys.min() ?? 0))
        let maxY = min(1, (ys.max() ?? 1))

        var r = CGRect(
            x: extent.minX + minX * extent.width,
            y: extent.minY + (1 - maxY) * extent.height,
            width: (maxX - minX) * extent.width,
            height: (maxY - minY) * extent.height
        )
        let dx = r.width * padding
        let dy = r.height * padding
        r = r.insetBy(dx: -dx, dy: -dy).intersection(extent)
        return r
    }

#if DEBUG
    private func publishDebug(rawVisionPoints: [CGPoint], devicePoints: [CGPoint], candidate: CandidateFrame, previewLayer: AVCaptureVideoPreviewLayer?) {
        guard let previewLayer else { return }
        let layerSize = previewLayer.bounds.size
        guard layerSize.width > 0, layerSize.height > 0 else { return }

        let layerPts = devicePoints.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
        let normalized = layerPts.map { CGPoint(x: $0.x / layerSize.width, y: $0.y / layerSize.height) }

        let rawDesc = rawVisionPoints.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " ")
        let mappedDesc = normalized.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " ")

        let roi = candidate.roiInFull
        let full = candidate.fullExtent
        let roiDesc = "\(candidate.tag) roi:(\(Int(roi.minX-full.minX)),\(Int(roi.minY-full.minY))) \(Int(roi.width))×\(Int(roi.height))"

        // Approximate scale/offset (useful if you later swap to manual mapping)
        let scale = layerSize.width / max(1, full.width)
        let info = QRDebugInfo(
            cameraSize: CGSize(width: full.width, height: full.height),
            roiDescription: roiDesc,
            videoGravity: previewLayer.videoGravity.rawValue,
            scale: scale,
            offsetX: 0,
            offsetY: 0,
            rawPointsDescription: rawDesc,
            mappedPointsDescription: mappedDesc
        )
        DispatchQueue.main.async { self.onDebug?(info) }
    }
#endif
}

// MARK: - Geometry helpers

private func orderPoints(_ points: [CGPoint]) -> [CGPoint] {
    // Works for both normalized and absolute points.
    // Identify TL/TR/BR/BL using sums and diffs.
    let sortedBySum = points.sorted { ($0.x + $0.y) < ($1.x + $1.y) }
    let tl = sortedBySum.first ?? .zero
    let br = sortedBySum.last ?? .zero

    let sortedByDiff = points.sorted { ($0.x - $0.y) < ($1.x - $1.y) }
    let bl = sortedByDiff.first ?? .zero
    let tr = sortedByDiff.last ?? .zero

    return [tl, tr, br, bl]
}

private func ema(_ a: CGPoint, _ b: CGPoint, alpha: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * alpha, y: a.y + (b.y - a.y) * alpha)
}

final class PreviewView: UIView {
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // layerClass makes our main layer an AVCaptureVideoPreviewLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layoutSubviews() { super.layoutSubviews() }
}
