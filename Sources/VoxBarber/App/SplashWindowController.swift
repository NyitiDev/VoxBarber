import AppKit

/// A splash (nyitó) képernyő ablak vezérlője.
///
/// Megjelenít egy 800×600 px méretű, nem méretezhető, de mozgatható ablakot,
/// amelyen a VoxBarber logó és egy START feliratú gomb látható.
/// A START gomb megnyomásakor meghívja az `onStart` closure-t, majd bezárja magát.
@MainActor
final class SplashWindowController: NSWindowController {

    /// Ezt a closure-t hívja a START gomb – a főablak megjelenítéséért felelős.
    var onStart: (() -> Void)?

    // MARK: – Inicializálás

    convenience init() {
        // Az ablak mérete: pontosan 800×600 logikai pont, de legfeljebb a képernyő látható területe.
        // Retina kijelzőn 1 pont = 2 fizikai pixel; a logikai pontméret adja az ablak vizuális méretét.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let w = min(800.0, screen.width)
        let h = min(600.0, screen.height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxBarber"
        // Az ablak teljes hátterén fogható és húzható
        window.isMovableByWindowBackground = true
        window.center()

        self.init(window: window)
        buildContentView()
    }

    // MARK: – Tartalom felépítése

    private func buildContentView() {
        guard let contentView = window?.contentView else { return }

        // Sötét háttér
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(
            red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0
        ).cgColor

        // ── START gomb (először adjuk hozzá, hogy a logo kényszerfeltételei hivatkozhassanak rá) ──
        let startButton = NSButton(title: "START", target: self, action: #selector(startTapped))
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.bezelStyle = .regularSquare
        startButton.isBordered = false
        startButton.focusRingType = .none
        startButton.wantsLayer = true
        startButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        startButton.layer?.cornerRadius = 8
        startButton.layer?.masksToBounds = true
        // Fehér, középre igazított felirat (a contentTintColor nem hat a sima title-re,
        // ha isBordered = false, ezért attribútumos címet használunk)
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        startButton.attributedTitle = NSAttributedString(
            string: "START",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .paragraphStyle: titleStyle
            ]
        )
        contentView.addSubview(startButton)

        // ── Logo ImageView ───────────────────────────────────────────────
        let logoView = NSImageView()
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.imageScaling = .scaleProportionallyUpOrDown
        // Engedélyezzük, hogy az AutoLayout szabadon zsugorítsa a képet
        logoView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logoView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if let logoURL = Bundle.module.url(forResource: "voxbarber_logo", withExtension: "png"),
           let logoImage = NSImage(contentsOf: logoURL) {
            logoView.image = logoImage
        } else {
            // Fallback: szöveges cím, ha a kép nem található
            let fallback = NSTextField(labelWithString: "VoxBarber")
            fallback.translatesAutoresizingMaskIntoConstraints = false
            fallback.font = NSFont.systemFont(ofSize: 52, weight: .bold)
            fallback.textColor = .white
            fallback.alignment = .center
            fallback.drawsBackground = false
            contentView.addSubview(fallback)
            NSLayoutConstraint.activate([
                fallback.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                fallback.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -40)
            ])
        }

        contentView.addSubview(logoView)

        NSLayoutConstraint.activate([
            // START gomb: fix méret, mindig látható az aljánál
            startButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            startButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),
            startButton.widthAnchor.constraint(equalToConstant: 160),
            startButton.heightAnchor.constraint(equalToConstant: 44),

            // Logo: a tetejétől 20 pt-ra kezdődik, az alja legalább 16 pt-ra legyen a gombtól
            logoView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            logoView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            logoView.bottomAnchor.constraint(equalTo: startButton.topAnchor, constant: -16),
            // Szélességre a tartalom 92%-át töltse ki
            logoView.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.92)
        ])
    }

    // MARK: – Akció

    /// START gomb megnyomásakor: először megmutatja a főablakot,
    /// majd bezárja a splash-t (sorrendben fontos az applicationShouldTerminate… miatt).
    @objc private func startTapped() {
        onStart?()
        close()
    }
}
