import UIKit

/// A short, non-interactive spray above the chat, starting at the envelope mouth.
final class EnvelopeOpeningBurstView: UIView {
    static func play(in card: UIView, artwork: CGRect, glyphs: [String]) -> EnvelopeOpeningBurstView? {
        guard !UIAccessibility.isReduceMotionEnabled, let window = card.window, !glyphs.isEmpty, artwork.width > 0 else { return nil }
        let burst = EnvelopeOpeningBurstView(frame: window.bounds)
        burst.isUserInteractionEnabled = false
        burst.accessibilityElementsHidden = true
        burst.clipsToBounds = true
        window.addSubview(burst)

        let start = card.convert(CGPoint(x: artwork.midX, y: artwork.minY + 5), to: burst)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak burst] in burst?.removeFromSuperview() }
        let count = glyphs.count * 2 + 1
        for index in 0 ..< count {
            let glyph = glyphs[index % glyphs.count]
            let direction: CGFloat = [-0.98, 0.86, -0.24, 0.50, -0.65, 0.99, 0.12][index]
            let diameter = CGFloat(18 + index % 3 * 3)
            let particle = UILabel(frame: CGRect(x: 0, y: 0, width: diameter + 4, height: diameter + 4))
            particle.textAlignment = .center
            particle.font = UIFont.systemFont(ofSize: diameter)
            particle.text = glyph
            particle.center = start
            particle.layer.opacity = 0
            burst.addSubview(particle)

            let endX = min(burst.bounds.maxX - 20, max(20, start.x + direction * min(190, burst.bounds.width * 0.46)))
            let dx = endX - start.x
            let upward = start.y > 160
            let end = CGPoint(x: endX, y: start.y + (upward ? -35 - CGFloat(index % 3) * 24 : 96 + CGFloat(index % 3) * 12))
            let curve = UIBezierPath()
            curve.move(to: start)
            curve.addQuadCurve(to: end, controlPoint: CGPoint(x: start.x + dx * 0.55, y: start.y + (upward ? -185 : 24) + 25 * abs(direction)))
            let position = CAKeyframeAnimation(keyPath: "position")
            position.path = curve.cgPath
            position.calculationMode = .linear
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.3, 1.0, 0.7]
            scale.keyTimes = [0, 0.25, 1]
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = -direction * 0.2
            rotation.toValue = direction * 0.7
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.12, 0.64, 1]
            let group = CAAnimationGroup()
            group.duration = 1.05 + Double(index % 3) * 0.07
            let animations: [CAAnimation] = [position, scale, rotation, opacity]
            for animation in animations { animation.duration = group.duration }
            group.animations = animations
            group.beginTime = particle.layer.convertTime(CACurrentMediaTime(), from: nil) + 0.12 + Double(index / glyphs.count) * 0.31 + Double(index % glyphs.count) * 0.095
            particle.layer.add(group, forKey: "envelope.openingBurst")
        }
        CATransaction.commit()
        return burst
    }
}
