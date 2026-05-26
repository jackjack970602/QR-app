//
//  QROverlay.swift
//  QR-effects
//
//  Created by k zhukovskaya on 25.05.2026.
//

import SwiftUI

struct QRQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
    var confidence: CGFloat
    var opacity: CGFloat
}

struct QROverlay: View {
    let quad: QRQuad?
    var debug: QRDebugInfo? = nil
    var detectPadding: CGFloat = 12
    var detectCornerRadius: CGFloat = 12
    var onMaskBecameVisible: (() -> Void)? = nil

    @State private var currentScale: CGFloat = 1.0
    @State private var wasPresent = false

    var body: some View {
        GeometryReader { proxy in
            let present = quad != nil && (quad?.confidence ?? 0) >= 0.35 && (quad?.opacity ?? 0) > 0.01

            if let quad, present {
                let rawPoints = [
                    quad.topLeft,
                    quad.topRight,
                    quad.bottomRight,
                    quad.bottomLeft,
                ].map { CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height) }

                let points = expandPolygon(
                    points: rawPoints,
                    padding: detectPadding,
                    in: CGRect(origin: .zero, size: proxy.size)
                )

                let animatedPoints = buildAnimatedPolygon(points: points, scale: currentScale)

                // Darken everything, cut out the QR polygon (even-odd fill).
                QRMaskCutout(points: animatedPoints, cornerRadius: detectCornerRadius)
                    .fill(.black.opacity(0.45 * quad.opacity), style: FillStyle(eoFill: true, antialiased: true))

                RoundedQRQuadShape(points: animatedPoints, cornerRadius: detectCornerRadius)
                    .fill(Color(red: 0.2588, green: 0.5451, blue: 0.9765).opacity(0.14 * quad.opacity))
                    .animation(.easeInOut(duration: 0.12), value: quad.opacity)
            }

            if let debug {
                VStack(alignment: .leading, spacing: 4) {
                    Text("preview: \(Int(proxy.size.width))×\(Int(proxy.size.height))")
                    Text("camera: \(Int(debug.cameraSize.width))×\(Int(debug.cameraSize.height))")
                    Text("roi: \(debug.roiDescription)")
                    Text("gravity: \(debug.videoGravity)")
                    Text(String(format: "scale: %.3f  off: %.1f / %.1f", debug.scale, debug.offsetX, debug.offsetY))
                    Text("points(raw): \(debug.rawPointsDescription)")
                    Text("points(mapped): \(debug.mappedPointsDescription)")
                }
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(8)
                .background(.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: (quad?.opacity ?? 0) > 0.01 && (quad?.confidence ?? 0) >= 0.35) { _, newValue in
            if newValue && !wasPresent {
                animateDetectIn()
            } else if !newValue && wasPresent {
                wasPresent = false
                currentScale = 0.3
            }
        }
    }

    private func animateDetectIn() {
        wasPresent = true
        currentScale = 0.3
        withAnimation(.timingCurve(0.33, 1.0, 0.68, 1.0, duration: 0.26)) {
            currentScale = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            onMaskBecameVisible?()
        }
    }
}

private func expandPolygon(points: [CGPoint], padding: CGFloat, in bounds: CGRect) -> [CGPoint] {
    guard points.count == 4, padding > 0 else { return points }

    let center = CGPoint(
        x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
        y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
    )

    return points.map { p in
        let dx = p.x - center.x
        let dy = p.y - center.y
        let len = max(0.0001, hypot(dx, dy))
        let nx = dx / len
        let ny = dy / len
        let expanded = CGPoint(x: p.x + nx * padding, y: p.y + ny * padding)
        return CGPoint(
            x: min(max(expanded.x, bounds.minX), bounds.maxX),
            y: min(max(expanded.y, bounds.minY), bounds.maxY)
        )
    }
}

private func buildAnimatedPolygon(points: [CGPoint], scale: CGFloat) -> [CGPoint] {
    guard points.count == 4 else { return points }
    let center = CGPoint(
        x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
        y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
    )
    return points.map { p in
        CGPoint(
            x: center.x + (p.x - center.x) * scale,
            y: center.y + (p.y - center.y) * scale
        )
    }
}

struct QRDebugInfo: Equatable {
    var cameraSize: CGSize
    var roiDescription: String
    var videoGravity: String
    var scale: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
    var rawPointsDescription: String
    var mappedPointsDescription: String
}

private struct QRMaskCutout: Shape {
    let points: [CGPoint]
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        guard points.count == 4 else { return p }
        p.addPath(RoundedQRQuadShape(points: points, cornerRadius: cornerRadius).path(in: rect))
        return p
    }
}

private struct RoundedQRQuadShape: Shape {
    let points: [CGPoint]
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard points.count == 4 else { return Path() }
        let r = max(0, cornerRadius)
        guard r > 0 else {
            var p = Path()
            p.move(to: points[0])
            p.addLine(to: points[1])
            p.addLine(to: points[2])
            p.addLine(to: points[3])
            p.closeSubpath()
            return p
        }

        let path = CGMutablePath()
        for i in 0..<4 {
            let prev = points[(i + 3) % 4]
            let curr = points[i]
            let next = points[(i + 1) % 4]

            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let l1 = max(0.0001, hypot(v1.x, v1.y))
            let l2 = max(0.0001, hypot(v2.x, v2.y))

            let d = min(r, min(l1, l2) * 0.5)
            let p1 = CGPoint(x: curr.x + v1.x / l1 * d, y: curr.y + v1.y / l1 * d)
            let p2 = CGPoint(x: curr.x + v2.x / l2 * d, y: curr.y + v2.y / l2 * d)

            if i == 0 {
                path.move(to: p1)
            } else {
                path.addLine(to: p1)
            }
            path.addArc(tangent1End: curr, tangent2End: p2, radius: d)
        }
        path.closeSubpath()
        return Path(path)
    }
}
