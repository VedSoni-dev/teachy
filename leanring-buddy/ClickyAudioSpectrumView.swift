//
//  ClickyAudioSpectrumView.swift
//  leanring-buddy
//
//  Idle / listening bar visualizer — adapted from boring.notch MusicVisualizer.
//

import AppKit
import SwiftUI

final class ClickyAudioSpectrumBars: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isAnimating = false
    private var animationTimer: Timer?

    var barColor: NSColor = .white {
        didSet { applyBarColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for barIndex in 0 ..< barCount {
            let xPosition = CGFloat(barIndex) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = barColor.cgColor
            barLayer.backgroundColor = barColor.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            )
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(0.35)
            layer?.addSublayer(barLayer)
        }
    }

    private func applyBarColor() {
        for barLayer in barLayers {
            barLayer.fillColor = barColor.cgColor
            barLayer.backgroundColor = barColor.cgColor
        }
    }

    func setAnimating(_ animating: Bool) {
        guard isAnimating != animating else { return }
        isAnimating = animating
        if animating {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        resetBars()
    }

    private func updateBars() {
        for (barIndex, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[barIndex]
            let targetScale = CGFloat.random(in: 0.35 ... 1.0)
            barScales[barIndex] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = 0.3
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (barIndex, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
            barScales[barIndex] = 0.35
        }
    }
}

struct ClickyAudioSpectrumView: NSViewRepresentable {
    var isAnimating: Bool
    var color: Color = .white

    func makeNSView(context: Context) -> ClickyAudioSpectrumBars {
        let spectrum = ClickyAudioSpectrumBars()
        spectrum.barColor = NSColor(color)
        spectrum.setAnimating(isAnimating)
        return spectrum
    }

    func updateNSView(_ nsView: ClickyAudioSpectrumBars, context: Context) {
        nsView.barColor = NSColor(color)
        nsView.setAnimating(isAnimating)
    }
}

/// Tiny blinking face for idle closed-notch wing (boring.notch MinimalFaceFeatures).
struct ClickyIdleFaceView: View {
    @State private var isBlinking = false

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                idleEye
                idleEye
            }

            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 3)

                GeometryReader { geometry in
                    Path { path in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        path.move(to: CGPoint(x: 0, y: height * 0.35))
                        path.addQuadCurve(
                            to: CGPoint(x: width, y: height * 0.35),
                            control: CGPoint(x: width / 2, y: height)
                        )
                    }
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                }
                .frame(width: 12, height: 8)
            }
        }
        .frame(width: 28, height: 20)
        .onAppear { startBlinking() }
    }

    private var idleEye: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.95))
            .frame(width: 4, height: isBlinking ? 1 : 4)
            .animation(.easeInOut(duration: 0.1), value: isBlinking)
    }

    private func startBlinking() {
        Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { _ in
            withAnimation(.spring(duration: 0.2)) {
                isBlinking = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(duration: 0.2)) {
                    isBlinking = false
                }
            }
        }
    }
}
