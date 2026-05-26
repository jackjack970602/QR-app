//
//  ContentView.swift
//  QR-effects
//
//  Created by k zhukovskaya on 25.05.2026.
//

import SwiftUI

struct ContentView: View {
    private enum ScanState: Equatable {
        case idle
        case recognized
        case sheetVisible
    }

    @State private var isDetected = false
    @State private var scannedCode: String?
    @State private var qrQuad: QRQuad?
    @State private var debugInfo: QRDebugInfo?
#if DEBUG
    @State private var debugDetected = false
#endif
    @State private var state: ScanState = .idle
    @State private var sheetVisible = false
    @State private var scanningEnabled = true
    @State private var resetCounter = 0
    @State private var pendingShowSheet = false

    private let cameraCornerRadius: CGFloat = 22
    private let cameraHeight: CGFloat = 680
    private let cameraTopOffset: CGFloat = 32
    private let cameraBorderWidth: CGFloat = 6
    
    private var effectiveDetected: Bool {
#if DEBUG
        return isDetected || debugDetected
#else
        return isDetected
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                ZStack(alignment: .bottom) {
                    QRScannerView(
                        isDetected: $isDetected,
                        scannedCode: $scannedCode,
                        quad: $qrQuad,
                        debugInfo: $debugInfo,
                        scanningEnabled: $scanningEnabled,
                        resetCounter: $resetCounter
                    )
                        .clipShape(RoundedRectangle(cornerRadius: cameraCornerRadius, style: .continuous))

                    QROverlay(
                        quad: qrQuad,
                        debug: debugInfo,
                        onMaskBecameVisible: {
                            if pendingShowSheet && !sheetVisible {
                                pendingShowSheet = false
                                showResultSheet()
                            }
                        }
                    )
                        .allowsHitTesting(false)

                    GlowBorder(
                        cornerRadius: cameraCornerRadius,
                        lineWidth: cameraBorderWidth,
                        isDetected: effectiveDetected,
                        scanning: true
                    )
                    .allowsHitTesting(false)

                    Image("camera-UI")
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width)
                        .padding(.bottom, cameraBorderWidth)
                }
                .frame(width: proxy.size.width, height: cameraHeight)
                .padding(.top, cameraTopOffset)
            }
        }
#if DEBUG
        .contentShape(Rectangle())
        .onTapGesture { debugDetected.toggle() }
#endif
        .onChange(of: scannedCode) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            onQrRecognized(newValue)
        }
        .sheet(isPresented: $sheetVisible) {
            ResultSheet(code: scannedCode) {
                resetScanner()
            }
            .presentationDetents([.height(200)])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(true)
        }
    }

    private func onQrRecognized(_ data: String) {
        guard state == .idle else { return }
        state = .recognized
        disableScanning()
        pendingShowSheet = true
        // Fallback in case mask callback doesn't fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            if self.pendingShowSheet && !self.sheetVisible {
                self.pendingShowSheet = false
                self.showResultSheet()
            }
        }
    }

    private func showResultSheet() {
        guard !sheetVisible else { return }
        sheetVisible = true
        state = .sheetVisible
    }

    private func hideResultSheet() {
        sheetVisible = false
        if state == .sheetVisible { state = .idle }
    }

    private func resetScanner() {
        hideResultSheet()
        scannedCode = nil
        isDetected = false
        qrQuad = nil
        pendingShowSheet = false
        resetCounter += 1
        enableScanning()
        state = .idle
    }

    private func enableScanning() { scanningEnabled = true }
    private func disableScanning() { scanningEnabled = false }
}

#Preview {
    ContentView()
        .previewLayout(.fixed(width: 375, height: 812))
}

private struct ResultSheet: View {
    let code: String?
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 40, height: 5)
                .padding(.top, 6)

            Text("QR распознан")
                .font(.headline)

            if let code, !code.isEmpty {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Text("Нажмите, чтобы сканировать снова")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
