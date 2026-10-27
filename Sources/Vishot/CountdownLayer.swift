import AppKit

enum CountdownPlacement {
    /// Global coordinates in either convention, provided target/display agree.
    /// Keep a readable badge even when the target is tiny; clamp at display edges.
    static func frame(target: CGRect, display: CGRect, size: CGSize, scale: CGFloat) -> CGRect {
        let margin: CGFloat = 16
        let x = min(max(target.midX - size.width / 2, display.minX + margin), display.maxX - size.width - margin)
        let y = min(max(target.midY - size.height / 2, display.minY + margin), display.maxY - size.height - margin)
        return CGRect(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale,
                      width: size.width, height: size.height)
    }
}

/// Built with each panel, with no timer, media dependencies, or animation delegates.
/// Re-rendering the same frame never restarts its animation.
final class CountdownLayer {
    let root = CALayer()
    private let number = CATextLayer()
    private var shown: CountdownFrame?

    init() {
        root.isHidden = true
        root.addSublayer(number)
        number.alignmentMode = .center
    }

    func hide() {
        shown = nil
        root.isHidden = true
        root.removeAllAnimations()
    }

    func show(_ frame: CountdownFrame, target: CGRect, display: CGRect, panel: CGRect,
              scale: CGFloat, style: CountdownStyle, reduceMotion: Bool) {
        let badge = CountdownPlacement.frame(target: target, display: display, size: style.size, scale: scale)
        root.frame = badge.offsetBy(dx: -panel.minX, dy: -panel.minY)
        style.plate.apply(to: root)
        root.shadowPath = style.plate.path(in: root.bounds)
        HUD.configure(number, font: style.font, color: style.text, scale: scale)
        let height = HUD.textSize("3", font: style.font).height
        number.frame = CGRect(x: 0, y: HUD.textY(style.font, lineHeight: height, in: style.size.height, scale: scale),
                              width: style.size.width, height: height)
        number.string = String(frame.number)
        root.isHidden = false
        guard shown != frame else { return }
        shown = frame
        root.removeAllAnimations()
        guard !reduceMotion else { return }
        let stepped = style.motion == .stepped
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0.45, 0]
        opacity.keyTimes = [0, 0.12, 0.78, 0.9, 1]
        opacity.calculationMode = stepped ? .discrete : .linear
        opacity.duration = 1
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .forwards
        root.add(opacity, forKey: "countdown.opacity")
        // Pixel's whole plate (including glyphs and hard shadow) must never be
        // resampled. Move by whole 4 pt cells instead of fractionally scaling it.
        let pop = CAKeyframeAnimation(keyPath: stepped ? "transform.translation.y" : "transform.scale")
        pop.values = stepped ? [8, 0, 0, -4] : [0.94, 1, 1, 1.035]
        pop.keyTimes = [0, 0.16, 0.78, 1]
        pop.calculationMode = stepped ? .discrete : .linear
        if !stepped { pop.timingFunctions = [.init(name: .easeOut), .init(name: .linear), .init(name: .easeIn)] }
        pop.duration = 1
        root.add(pop, forKey: "countdown.pop")
    }
}
