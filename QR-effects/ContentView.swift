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
        case resultVisible
    }

    @State private var isDetected = false
    @State private var scannedCode: String?
    @State private var qrQuad: QRQuad?
    @State private var debugInfo: QRDebugInfo?
#if DEBUG
    @State private var debugDetected = false
#endif
    @State private var state: ScanState = .idle
    @State private var resultVisible = false
    @State private var scanningEnabled = true
    @State private var resetCounter = 0
    @State private var pendingShowResult = false
    @State private var resultShowFallbackWorkItem: DispatchWorkItem?

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
                            if pendingShowResult && !resultVisible {
                                pendingShowResult = false
                                scheduleResultScreenAfterMask()
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

                if resultVisible {
                    ResultScreen {
                        resetScanner()
                    }
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
                }
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
    }

    private func onQrRecognized(_ data: String) {
        guard state == .idle else { return }
        state = .recognized
        disableScanning()
        pendingShowResult = true

        resultShowFallbackWorkItem?.cancel()
        let fallback = DispatchWorkItem {
            if self.pendingShowResult && !self.resultVisible {
                self.pendingShowResult = false
                self.scheduleResultScreenAfterMask()
            }
        }
        resultShowFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)
    }

    private func showResultScreen() {
        guard !resultVisible else { return }
        withAnimation(.easeInOut) {
            resultVisible = true
        }
        state = .resultVisible
    }

    private func scheduleResultScreenAfterMask() {
        resultShowFallbackWorkItem?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if state == .recognized && !resultVisible {
                showResultScreen()
            }
        }
    }

    private func hideResultScreen() {
        withAnimation(.easeInOut) {
            resultVisible = false
        }
        if state == .resultVisible { state = .idle }
    }

    private func resetScanner() {
        hideResultScreen()
        scannedCode = nil
        isDetected = false
        qrQuad = nil
        pendingShowResult = false
        resultShowFallbackWorkItem?.cancel()
        resultShowFallbackWorkItem = nil
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

private struct ResultScreen: View {
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Image("screen-result")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}
