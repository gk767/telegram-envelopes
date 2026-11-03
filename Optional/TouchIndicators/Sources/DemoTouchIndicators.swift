import UIKit

#if targetEnvironment(simulator)
/// Optional filming aid. Observes events after UIKit dispatch, without views,
/// gesture recognizers, swizzling, hit testing or event synthesis.
public final class DemoTouchIndicators {
    private var active: [ObjectIdentifier: CAShapeLayer] = [:]
    private var retiring: [CAShapeLayer] = []
    private var inactiveObserver: NSObjectProtocol?
    private let enabled: Bool

    public init() {
        self.enabled = !ProcessInfo.processInfo.arguments.contains("-DisableDemoTouches")
        self.inactiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let observer = self.inactiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        self.removeAll()
    }

    public func handle(_ event: UIEvent) {
        guard self.enabled, event.type == .touches, let touches = event.allTouches else {
            return
        }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            switch touch.phase {
            case .began:
                guard self.active[key] == nil, self.active.count < 5,
                      let window = touch.window, !window.isHidden else {
                    continue
                }
                let layer = self.begin(at: touch.location(in: window), in: window.layer)
                self.active[key] = layer
            case .moved, .stationary:
                guard let layer = self.active[key], let window = touch.window else {
                    continue
                }
                let latest = event.coalescedTouches(for: touch)?.last ?? touch
                self.move(layer, to: latest.location(in: window))
            case .ended, .cancelled:
                guard let layer = self.active.removeValue(forKey: key) else {
                    continue
                }
                if let window = touch.window {
                    self.move(layer, to: touch.location(in: window))
                }
                self.finish(layer, cancelled: touch.phase == .cancelled)
            default:
                break
            }
        }
    }

    private func begin(at point: CGPoint, in host: CALayer) -> CAShapeLayer {
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        dot.path = UIBezierPath(ovalIn: dot.bounds.insetBy(dx: 1, dy: 1)).cgPath
        dot.fillColor = UIColor(white: 0.28, alpha: 0.26).cgColor
        dot.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        dot.lineWidth = 1.1
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.12
        dot.shadowRadius = 2.5
        dot.shadowOffset = CGSize(width: 0, height: 1)
        dot.shadowPath = dot.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = point
        host.addSublayer(dot)
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.10
        dot.add(fade, forKey: "touchAppear")
        if !UIAccessibility.isReduceMotionEnabled {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.86
            scale.toValue = 1
            scale.duration = 0.14
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dot.add(scale, forKey: "touchPress")
        }
        return dot
    }

    private func move(_ layer: CAShapeLayer, to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = point
        CATransaction.commit()
    }

    private func finish(_ dot: CAShapeLayer, cancelled: Bool) {
        let reduced = UIAccessibility.isReduceMotionEnabled
        let duration: CFTimeInterval = reduced || cancelled ? 0.16 : 0.28
        if !cancelled && !reduced, let host = dot.superlayer {
            let wave = CAShapeLayer()
            wave.bounds = dot.bounds
            wave.path = UIBezierPath(ovalIn: wave.bounds.insetBy(dx: 13, dy: 13)).cgPath
            wave.fillColor = UIColor.clear.cgColor
            wave.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
            wave.lineWidth = 0.9
            wave.position = dot.position
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.insertSublayer(wave, below: dot)
            CATransaction.commit()
            self.retire(wave, duration: 0.42, scale: 3.78)
        }
        self.retire(dot, duration: duration, scale: reduced || cancelled ? 1 : 1.08)
    }

    private func retire(_ layer: CAShapeLayer, duration: CFTimeInterval, scale: CGFloat) {
        self.retiring.append(layer)
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        let transform = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            guard let layer = layer else { return }
            layer.removeFromSuperlayer()
            self?.retiring.removeAll(where: { $0 === layer })
        }
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: transform)
        grow.toValue = NSValue(caTransform3D: layer.transform)
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "touchRelease")
        CATransaction.commit()
    }

    private func removeAll() {
        for layer in Array(self.active.values) + self.retiring {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        self.active.removeAll()
        self.retiring.removeAll()
    }
}
#endif
