import AppKit

// MARK: - PillButton

/// Orange accent pill-shaped button.
final class PillButton: NSButton {

    private let accentColor: NSColor

    init(title: String, accent: NSColor = AppColors.accent) {
        self.accentColor = accent
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.backgroundColor = accent.cgColor
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        // Explicit attributed title prevents any system-applied strikethrough
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.black,
            .strikethroughStyle: 0
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attrs)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.activeInKeyWindow, .inVisibleRect,
                                                .mouseEnteredAndExited],
                                      owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().layer?.backgroundColor = accentColor.blended(withFraction: 0.2, of: .white)?.cgColor
                ?? accentColor.cgColor
        }
    }
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().layer?.backgroundColor = accentColor.cgColor
        }
    }
}

// MARK: - IconButton

/// Borderless SF Symbol toolbar button with hover highlight.
final class IconButton: NSButton {

    init(symbol: String, tip: String, size: CGFloat = 16, buttonSize: CGFloat = 30) {
        super.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        toolTip = tip
        isBordered = false
        wantsLayer = true
        contentTintColor = NSColor.white.withAlphaComponent(0.80)
        layer?.cornerRadius = 6
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonSize),
            heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.activeInKeyWindow, .inVisibleRect,
                                                .mouseEnteredAndExited],
                                      owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            animator().layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
    }
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
