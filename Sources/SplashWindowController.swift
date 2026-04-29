import AppKit

final class SplashWindowController: NSWindowController {

    convenience init() {
        let width: CGFloat    = 420
        let imageH: CGFloat   = 340   // original image area
        let footerH: CGFloat  = 72    // button strip below the image
        let height: CGFloat   = imageH + footerH
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)

        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating

        self.init(window: window)
        buildContent(imageH: imageH, footerH: footerH)
    }

    private func buildContent(imageH: CGFloat, footerH: CGFloat) {
        guard let cv = window?.contentView else { return }
        let totalH = imageH + footerH

        // ── Outer rounded container ─────────────────────────────────
        let container = NSView(frame: cv.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = AppColors.surface.cgColor
        cv.addSubview(container)

        // ── Logo image (top portion) ────────────────────────────────
        let bgImage = NSImageView(frame: CGRect(x: 0, y: footerH, width: cv.bounds.width, height: imageH))
        bgImage.autoresizingMask = [.width, .minYMargin]
        bgImage.imageScaling = .scaleAxesIndependently
        if let path = Bundle.main.path(forResource: "voxbarber_logo", ofType: "png"),
           let img  = NSImage(contentsOfFile: path) {
            bgImage.image = img
        }
        container.addSubview(bgImage)

        // ── Footer strip (below image) ──────────────────────────────
        let footer = NSView(frame: CGRect(x: 0, y: 0, width: cv.bounds.width, height: footerH))
        footer.autoresizingMask = [.width]
        footer.wantsLayer = true
        footer.layer?.backgroundColor = AppColors.background.cgColor
        container.addSubview(footer)

        // Thin separator line between image and footer
        let sep = NSView(frame: CGRect(x: 0, y: footerH - 1, width: cv.bounds.width, height: 1))
        sep.autoresizingMask = [.width]
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        container.addSubview(sep)

        // ── Subtle outer border ─────────────────────────────────────
        let border = NSView(frame: cv.bounds)
        border.autoresizingMask = [.width, .height]
        border.wantsLayer = true
        border.layer?.cornerRadius = 18
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        border.layer?.borderWidth = 1
        border.layer?.masksToBounds = true
        cv.addSubview(border)

        // ── Get Started button ──────────────────────────────────────
        let btn = PillButton(title: "Get Started")
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.target = self
        btn.action = #selector(continuePressed)
        footer.addSubview(btn)

        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 160),
            btn.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    @objc private func continuePressed() {
        (NSApp.delegate as? AppDelegate)?.splashDidFinish()
    }
}
