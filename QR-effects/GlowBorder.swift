//
//  GlowBorder.swift
//  QR-effects
//
//  Created by k zhukovskaya on 25.05.2026.
//

import SwiftUI

struct GlowBorder: View {
    var cornerRadius: CGFloat = 22
    var lineWidth: CGFloat = 6
    var glowColor: Color = Color(red: 0.2588, green: 0.5451, blue: 0.9765) // #428BF9
    var isDetected: Bool = false
    var scanning: Bool = true

    @State private var flash: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            // Base border "inside"
            shape
                .strokeBorder(Color.white.opacity(0.05), lineWidth: lineWidth)

            ScanningGlow(shape: shape, lineWidth: lineWidth, glowColor: glowColor, isActive: scanning && !isDetected)
                .opacity(scanning && !isDetected ? 1 : 0)

            DetectedGlow(shape: shape, lineWidth: lineWidth, glowColor: glowColor, isActive: isDetected, flash: flash)
                .opacity(isDetected ? 1 : 0)
        }
        .compositingGroup()
        .drawingGroup(opaque: false, colorMode: .linear)
        .animation(.easeInOut(duration: 0.28), value: isDetected)
        .onChange(of: isDetected) { _, newValue in
            guard newValue else { return }
            flash = 0
            withAnimation(.easeOut(duration: 0.22)) { flash = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeIn(duration: 0.45)) { flash = 0 }
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        GlowBorder(isDetected: false, scanning: true)
            .frame(width: 375, height: 665)
            .padding(.top, 44)
    }
    .previewLayout(.fixed(width: 375, height: 812))
}

private struct ScanningGlow: View {
    let shape: RoundedRectangle
    let lineWidth: CGFloat
    let glowColor: Color
    let isActive: Bool

    @State private var phase: CGFloat = 0

    private var glowGradient: AngularGradient {
        // Soft bright segment; rest transparent (smooth edges to avoid "sharp" motion).
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.40),
                .init(color: glowColor.opacity(0.10), location: 0.46),
                .init(color: glowColor.opacity(0.55), location: 0.50),
                .init(color: glowColor.opacity(0.10), location: 0.54),
                .init(color: .clear, location: 0.60),
                .init(color: .clear, location: 1.00),
            ]),
            center: .center,
            angle: .degrees(Double(phase) * 360.0)
        )
    }

    private var segmentGradient: AngularGradient {
        // A solid colored segment on the border, synchronized with the glow.
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.42),
                .init(color: glowColor.opacity(0.20), location: 0.47),
                .init(color: glowColor.opacity(1.00), location: 0.50),
                .init(color: glowColor.opacity(0.20), location: 0.53),
                .init(color: .clear, location: 0.58),
                .init(color: .clear, location: 1.00),
            ]),
            center: .center,
            angle: .degrees(Double(phase) * 360.0)
        )
    }

    var body: some View {
        ZStack {
            // Inner-edge moving highlight
            shape
                .strokeBorder(glowGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .blur(radius: 10)

            shape
                .strokeBorder(glowGradient, style: StrokeStyle(lineWidth: lineWidth * 2.2, lineCap: .round, lineJoin: .round))
                .blur(radius: 22)
                .opacity(0.75)

            // Solid colored segment (no blur) that runs with the glow
            shape
                .strokeBorder(segmentGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .opacity(0.95)
                .blendMode(.screen)
                .blur(radius: 0.6)

            // Bottom outside glow (spills below the frame)
            shape
                .stroke(glowGradient, lineWidth: lineWidth * 2.2)
                .blur(radius: 26)
                .opacity(0.55)
                .offset(y: 12)
                .padding(.bottom, 40)
                .mask(
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: proxy.size.height * 0.42)
                        }
                    }
                )

            // Subtle constant bottom bloom (outside), like in the reference
            shape
                .stroke(glowColor.opacity(0.14), lineWidth: lineWidth * 2.0)
                .blur(radius: 20)
                .offset(y: 16)
                .padding(.bottom, 60)
                .mask(
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: proxy.size.height * 0.26)
                        }
                    }
                )
        }
        .onAppear {
            guard isActive else { return }
            phase = 0
            withAnimation(.linear(duration: 4.32).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .onChange(of: isActive) { _, newValue in
            guard newValue else { return }
            phase = 0
            withAnimation(.linear(duration: 4.32).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

private struct DetectedGlow: View {
    let shape: RoundedRectangle
    let lineWidth: CGFloat
    let glowColor: Color
    let isActive: Bool
    let flash: CGFloat

    @State private var pulse = false

    var body: some View {
        let stroke1 = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let stroke2 = StrokeStyle(lineWidth: lineWidth * 2, lineCap: .round, lineJoin: .round)
        let stroke3 = StrokeStyle(lineWidth: lineWidth * 4, lineCap: .round, lineJoin: .round)

        ZStack {
            shape
                .strokeBorder(glowColor.opacity(0.40 + 0.15 * flash), style: stroke1)

            shape
                .strokeBorder(glowColor.opacity(0.30 + 0.18 * flash), style: stroke2)
                .blur(radius: 10)

            shape
                .strokeBorder(glowColor.opacity(0.22 + 0.20 * flash), style: stroke3)
                .blur(radius: 22)
        }
        .scaleEffect(pulse ? 1.002 : 1.0)
        .opacity(pulse ? 1.0 : 0.85)
        .onAppear { restartIfNeeded() }
        .onChange(of: isActive) { _, _ in restartIfNeeded() }
    }

    private func restartIfNeeded() {
        guard isActive else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
    }
}
