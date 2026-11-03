import Foundation
import UIKit
import Display
import TelegramEnvelopes

/// Shared transparent artwork. The paper surfaces are drawn once per size; the
/// hinge and the letter animate independently on the compositor.
public final class EnvelopeArtworkView: UIView {
    private let body = CALayer()
    private let pocket = CALayer()
    private let lid = CALayer()
    private let letter = UIView()
    private let amount = UILabel()
    private var renderedSize = CGSize.zero
    private var closedLid: CGImage?
    private var openLid: CGImage?
    private var open = false

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.isUserInteractionEnabled = false
        self.layer.addSublayer(self.body)
        self.addSubview(self.letter)
        self.letter.addSubview(self.amount)
        self.layer.addSublayer(self.pocket)
        self.layer.addSublayer(self.lid)
        self.body.shadowColor = UIColor(red: 0.16, green: 0.27, blue: 0.41, alpha: 1).cgColor
        self.body.shadowOpacity = 0.24
        self.body.shadowRadius = 3
        self.body.shadowOffset = CGSize(width: 0, height: 2)
        self.letter.backgroundColor = UIColor(red: 0.945, green: 0.952, blue: 0.965, alpha: 1)
        self.letter.layer.shadowColor = UIColor(red: 0.25, green: 0.31, blue: 0.42, alpha: 1).cgColor
        self.letter.layer.shadowOpacity = 0.22
        self.letter.layer.shadowRadius = 3
        self.letter.layer.shadowOffset = CGSize(width: 0, height: 2)
        self.letter.layer.cornerCurve = .continuous
        self.letter.layer.cornerRadius = 6
        self.letter.layer.borderWidth = 0.5
        self.letter.layer.borderColor = UIColor(red: 0.49, green: 0.53, blue: 0.60, alpha: 0.23).cgColor
        self.amount.textAlignment = .center
        self.amount.font = .systemFont(ofSize: 20, weight: .semibold)
        self.amount.textColor = UIColor(white: 0.16, alpha: 1)
        self.amount.adjustsFontSizeToFitWidth = true
        self.amount.minimumScaleFactor = 0.45
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func update(style: EnvelopeStyle, accent: UIColor, amount: String = "") {
        self.amount.text = amount
    }

    // Use the reference's proportions in drawing space, including its rolled
    // top corners, the concave folds under the flap, and the recessed wax face.
    private func surface(_ index: Int, size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { renderer in
            let c = renderer.cgContext
            c.scaleBy(x: size.width / 264, y: size.height / 198)
            func color(_ hex: Int) -> UIColor {
                UIColor(red: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
            }
            func gradient(_ path: UIBezierPath, _ stops: [Int], _ start: CGPoint, _ end: CGPoint) {
                c.saveGState()
                path.addClip()
                let colors = stops.map { color($0).cgColor }
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil) {
                    c.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                c.restoreGState()
            }
            let shell = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 262, height: 196), cornerRadius: 16)
            let blueEdge = color(0x70a9d7).withAlphaComponent(0.40)
            if index == 0 {
                gradient(shell, [0xf8faff, 0xe6ebf5, 0xd7dfed], CGPoint(x: 54, y: 0), CGPoint(x: 180, y: 198))
                blueEdge.setStroke(); shell.lineWidth = 1; shell.stroke()
            } else if index == 1 {
                let fold = UIBezierPath()
                fold.move(to: CGPoint(x: 0, y: 1))
                fold.addQuadCurve(to: CGPoint(x: 132, y: 123), controlPoint: CGPoint(x: 69, y: 83))
                fold.addQuadCurve(to: CGPoint(x: 264, y: 1), controlPoint: CGPoint(x: 190, y: 84))
                fold.addLine(to: CGPoint(x: 264, y: 198)); fold.addLine(to: CGPoint(x: 0, y: 198)); fold.close()
                shell.addClip()
                gradient(fold, [0xf4f6fc, 0xe1e6f1], CGPoint(x: 100, y: 70), CGPoint(x: 150, y: 198))
                let front = UIBezierPath()
                front.move(to: CGPoint(x: 0, y: 198))
                front.addQuadCurve(to: CGPoint(x: 117, y: 99), controlPoint: CGPoint(x: 67, y: 138))
                front.addQuadCurve(to: CGPoint(x: 147, y: 99), controlPoint: CGPoint(x: 132, y: 89))
                front.addQuadCurve(to: CGPoint(x: 264, y: 198), controlPoint: CGPoint(x: 213, y: 151))
                front.close()
                gradient(front, [0xf1f4fb, 0xe1e6f0], CGPoint(x: 112, y: 93), CGPoint(x: 148, y: 198))
                UIColor.white.withAlphaComponent(0.72).setStroke(); front.lineWidth = 1; front.stroke()
                let edge = UIBezierPath()
                edge.move(to: CGPoint(x: 1, y: 16))
                edge.addLine(to: CGPoint(x: 1, y: 181))
                edge.addQuadCurve(to: CGPoint(x: 17, y: 197), controlPoint: CGPoint(x: 1, y: 197))
                edge.addLine(to: CGPoint(x: 247, y: 197))
                edge.addQuadCurve(to: CGPoint(x: 263, y: 181), controlPoint: CGPoint(x: 263, y: 197))
                edge.addLine(to: CGPoint(x: 263, y: 16))
                blueEdge.setStroke(); edge.lineWidth = 0.8; edge.stroke()
            } else if index == 3 {
                let back = UIBezierPath()
                back.move(to: CGPoint(x: 1, y: 0))
                back.addLine(to: CGPoint(x: 118, y: 119))
                back.addQuadCurve(to: CGPoint(x: 146, y: 119), controlPoint: CGPoint(x: 132, y: 132))
                back.addLine(to: CGPoint(x: 263, y: 0))
                back.close()
                gradient(back, [0xd8e0ef, 0xecf0f8, 0xf6f7fc], CGPoint(x: 132, y: 0), CGPoint(x: 132, y: 126))
                color(0xb4c2d8).withAlphaComponent(0.45).setStroke()
                back.lineWidth = 0.8
                back.stroke()
            } else {
                let flap = UIBezierPath()
                flap.move(to: CGPoint(x: 2, y: 16))
                flap.addQuadCurve(to: CGPoint(x: 18, y: 2), controlPoint: CGPoint(x: 3, y: 2))
                flap.addLine(to: CGPoint(x: 246, y: 2))
                flap.addQuadCurve(to: CGPoint(x: 262, y: 16), controlPoint: CGPoint(x: 260, y: 2))
                flap.addQuadCurve(to: CGPoint(x: 251, y: 33), controlPoint: CGPoint(x: 262, y: 24))
                flap.addLine(to: CGPoint(x: 149, y: 110))
                flap.addQuadCurve(to: CGPoint(x: 115, y: 110), controlPoint: CGPoint(x: 132, y: 123))
                flap.addLine(to: CGPoint(x: 13, y: 33))
                flap.addQuadCurve(to: CGPoint(x: 2, y: 16), controlPoint: CGPoint(x: 2, y: 24))
                flap.close()
                c.saveGState()
                c.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: color(0x5b6882).withAlphaComponent(0.46).cgColor)
                color(0xecf0f8).setFill(); flap.fill(); c.restoreGState()
                gradient(flap, [0xffffff, 0xf1f3fa, 0xe3e8f3], CGPoint(x: 64, y: 0), CGPoint(x: 163, y: 119))
                UIColor.white.withAlphaComponent(0.65).setStroke(); flap.lineWidth = 0.9; flap.stroke()
                let wax = UIBezierPath()
                let center = CGPoint(x: 132, y: 102)
                for i in 0 ... 120 {
                    let a = CGFloat(i) * .pi / 60
                    let r = 31 * (1 + 0.046 * cos(7*a) + 0.023 * sin(9*a))
                    let point = CGPoint(x: center.x + r*cos(a), y: center.y + r*sin(a))
                    if i == 0 { wax.move(to: point) } else { wax.addLine(to: point) }
                }
                wax.close()
                c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: color(0x173c69).withAlphaComponent(0.48).cgColor)
                color(0x1988de).setFill(); wax.fill(); c.restoreGState()
                gradient(wax, [0x8cddff, 0x2aaafa, 0x0074d9, 0x0651a5], CGPoint(x: 119,y: 72), CGPoint(x: 147,y: 134))
                let rim = UIBezierPath(ovalIn: CGRect(x: 108,y: 78,width: 48,height: 48))
                gradient(rim, [0x075ca8, 0x0879ce, 0x73cbff], CGPoint(x: 121,y: 78), CGPoint(x: 143,y: 125))
                let face = UIBezierPath(ovalIn: CGRect(x: 110,y: 80,width: 44,height: 44))
                gradient(face, [0x169aee, 0x0587e2, 0x0874cf], CGPoint(x: 116,y: 83), CGPoint(x: 149,y: 121))
            }
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let size = self.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.body.frame = self.bounds
        self.pocket.frame = self.bounds
        self.lid.anchorPoint = CGPoint(x: 0.5, y: 0)
        self.lid.bounds = self.bounds
        self.lid.position = CGPoint(x: size.width * 0.5, y: 0)
        self.letter.bounds = CGRect(x: 0, y: 0, width: size.width * 0.80, height: size.height * 0.79)
        self.letter.center = CGPoint(x: size.width / 2, y: size.height * 0.55)
        self.amount.frame = self.letter.bounds.insetBy(dx: 6, dy: 4)
        if self.renderedSize != size {
            self.renderedSize = size
            self.closedLid = self.surface(2, size: size).cgImage
            self.openLid = self.surface(3, size: size).cgImage
            for (index, layer) in [self.body, self.pocket, self.lid].enumerated() {
                let image = self.surface(index, size: size)
                layer.contentsScale = image.scale
                layer.contents = index == 2 ? (self.open ? self.openLid : self.closedLid) : image.cgImage
            }
        }
        CATransaction.commit()
    }

    private func hinge(_ angle: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = -1 / max(350, self.bounds.width * 2.8)
        return CATransform3DRotate(t, angle, 1, 0, 0)
    }

    /// A single damped tilt and lift, in the artwork's own coordinate space.
    public func settle(opening: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let strength: Double = opening ? 1 : 1.18
        let times: [NSNumber] = [0, 0.19, 0.44, 0.73, 1]
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = [0, -0.085 * strength, 0.049 * strength, -0.014 * strength, 0]
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, -4.2 * strength, -1.8 * strength, 0.6 * strength, 0]
        let group = CAAnimationGroup()
        group.duration = 0.92
        for motion in [turn, lift] {
            motion.keyTimes = times
            motion.duration = group.duration
            motion.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        }
        group.animations = [turn, lift]
        self.layer.add(group, forKey: "envelope.settle")
    }

    public func setOpen(_ open: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        self.layoutIfNeeded()
        let changed = self.open != open
        self.open = open
        let move = animated && changed && !UIAccessibility.isReduceMotionEnabled
        let angle: CGFloat = open ? -.pi * 0.91 : 0
        let offset = open ? -self.bounds.height * 0.71 : 0
        let previous = self.lid.presentation()?.transform ?? self.lid.transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.body.zPosition = -4
        self.letter.layer.zPosition = -1
        self.lid.zPosition = open ? -2 : 1
        self.lid.transform = self.hinge(angle)
        self.lid.contents = open ? self.openLid : self.closedLid
        CATransaction.commit()
        if move {
            if open { self.settle(opening: true) }
            let turn = CABasicAnimation(keyPath: "transform")
            turn.fromValue = NSValue(caTransform3D: previous)
            turn.toValue = NSValue(caTransform3D: self.lid.transform)
            turn.duration = 0.57
            turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.32,0.02,0.16,1)
            self.lid.add(turn, forKey: "fold")
            if let closed = self.closedLid, let back = self.openLid {
                let faces = CAKeyframeAnimation(keyPath: "contents")
                faces.values = open ? [closed, closed, back, back] : [back, back, closed, closed]
                faces.keyTimes = [0, 0.43, 0.44, 1]
                faces.calculationMode = .discrete
                faces.duration = turn.duration
                self.lid.add(faces, forKey: "faces")
            }
            if open {
                let unfurl = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                unfurl.values = [0, -0.035, 0.018, 0]
                unfurl.keyTimes = [0, 0.42, 0.72, 1]
                unfurl.duration = 0.95
                unfurl.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                self.letter.layer.add(unfurl, forKey: "unfurl")
            }
            let depth = CAKeyframeAnimation(keyPath: "zPosition")
            depth.values = [1, 1, -2, -2]; depth.keyTimes = [0,0.42,0.44,1]; depth.duration = turn.duration
            self.lid.add(depth, forKey: "depth")
        } else {
            self.lid.removeAllAnimations()
        }
        UIView.animate(withDuration: move ? 0.65 : 0, delay: move ? 0.18 : 0, usingSpringWithDamping: 0.91, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            self.letter.transform = CGAffineTransform(translationX: 0, y: offset)
        }, completion: { _ in completion?() })
    }
}

public enum EnvelopeMotion {
    public static func spring(_ animations: @escaping () -> Void, reduceMotion: Bool = false, completion: ((Bool) -> Void)? = nil) {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled || reduceMotion ? 0 : 0.4, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: animations, completion: completion)
    }
}
