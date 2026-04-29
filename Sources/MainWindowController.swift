import AppKit
import AVFoundation

// A plain NSView with flipped coordinates (Y=0 at top) for natural top-to-bottom stacking.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The single persistent "hub" window.
/// Audio files open as free-floating AudioTrackPanel views on a scrollable canvas.
final class MainWindowController: NSWindowController {

    // MARK: – Subviews

    private let scrollView = NSScrollView()
    private let trackCanvas = FlippedView()          // free-form document view
    private var canvasHeightConstraint: NSLayoutConstraint!

    private let volumeSlider: NSSlider = {
        let s = NSSlider(value: 1.0, minValue: 0.0, maxValue: 2.0, target: nil, action: nil)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.sliderType = .linear
        return s
    }()

    // MARK: – State

    private var trackPanels: [AudioTrackPanel] = []
    private var placeholderView: NSView?
    private var focusedPanel: AudioTrackPanel?   // last added/interacted panel for space bar
    private var keyMonitor: Any?

    // MARK: – Init

    convenience init() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = max(1100, screen.width  * 0.78)
        let h: CGFloat = max(700,  screen.height * 0.78)
        let origin = CGPoint(x: screen.midX - w / 2, y: screen.midY - h / 2)

        let window = NSWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: w, height: h)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize                    = CGSize(width: 900, height: 600)
        window.titlebarAppearsTransparent = true
        window.titleVisibility            = .hidden
        window.appearance                 = NSAppearance(named: .darkAqua)
        window.backgroundColor            = AppColors.background
        window.title                      = "VoxBarber"

        self.init(window: window)
        buildUI()

        // Space bar = play / pause
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.keyCode == 49 /* space */,
                  !(event.window?.firstResponder is NSText) else { return event }
            self.handleSpaceBar()
            return nil
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResized),
            name: NSWindow.didResizeNotification, object: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: – UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true

        let vfx = NSVisualEffectView(frame: cv.bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material = .underWindowBackground
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        cv.addSubview(vfx)

        let toolbar = buildToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(toolbar)

        let sep = NSView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        cv.addSubview(sep)

        // ── Scroll view + canvas ───────────────────────────────────────
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.backgroundColor       = AppColors.background
        scrollView.drawsBackground       = true
        cv.addSubview(scrollView)

        // Canvas: fills scroll view width, height managed by constraint
        trackCanvas.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = trackCanvas

        canvasHeightConstraint = trackCanvas.heightAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([
            trackCanvas.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor),
            trackCanvas.trailingAnchor.constraint(
                equalTo: scrollView.contentView.trailingAnchor),
            trackCanvas.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor),
            canvasHeightConstraint,
        ])

        // Placeholder
        let ph = makePlaceholder()
        placeholderView = ph
        trackCanvas.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.centerXAnchor.constraint(equalTo: trackCanvas.centerXAnchor),
            ph.centerYAnchor.constraint(equalTo: trackCanvas.centerYAnchor),
            ph.widthAnchor.constraint(equalToConstant: 380),
            ph.heightAnchor.constraint(equalToConstant: 120),
        ])

        // ── Layout ─────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: cv.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),

            sep.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar; bar.blendingMode = .withinWindow
        bar.appearance = NSAppearance(named: .darkAqua); bar.state = .active

        let appLabel = NSTextField(labelWithString: "VoxBarber")
        appLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        appLabel.textColor = .white

        let openBtn = PillButton(title: "Open File")
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.target = self; openBtn.action = #selector(openFilePressed)
        NSLayoutConstraint.activate([
            openBtn.widthAnchor.constraint(equalToConstant: 96),
            openBtn.heightAnchor.constraint(equalToConstant: 30),
        ])

        let volIcon = NSImageView()
        let volCfg  = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        volIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "Volume")?
            .withSymbolConfiguration(volCfg)
        volIcon.contentTintColor = NSColor.white.withAlphaComponent(0.50)
        volIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            volIcon.widthAnchor.constraint(equalToConstant: 22),
            volIcon.heightAnchor.constraint(equalToConstant: 22),
        ])

        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let hStack = NSStackView(views: [appLabel, openBtn, volIcon, volumeSlider])
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.orientation = .horizontal; hStack.alignment = .centerY; hStack.spacing = 14
        bar.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            hStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 8),
        ])
        return bar
    }

    private func makePlaceholder() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString:
            "Nincs megnyitott fájl\nFile \u{2192} Open  (\u{2318}O)")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = NSColor.white.withAlphaComponent(0.22)
        label.alignment = .center
        label.maximumNumberOfLines = 3
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    // MARK: – Track management

    func addTrackPanel(for document: AudioDocument) {
        if trackPanels.isEmpty, let ph = placeholderView {
            ph.removeFromSuperview()
            placeholderView = nil
        }

        let panel = AudioTrackPanel(document: document)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.removeTrackPanel(panel)
        }
        panel.onFrameChange = { [weak self] in self?.updateCanvasHeight() }

        // Position below existing panels, full canvas width minus padding
        let padding: CGFloat = 14
        let nextY = trackPanels.map { $0.frame.maxY + 10 }.max() ?? padding
        let canvasW = scrollView.contentView.bounds.width
        let panelW  = max(400, canvasW - padding * 2)
        panel.frame = CGRect(x: padding, y: nextY, width: panelW, height: 260)

        trackCanvas.addSubview(panel)
        trackPanels.append(panel)
        focusedPanel = panel
        updateCanvasHeight()

        DispatchQueue.main.async {
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: nextY))
        }
    }

    private func removeTrackPanel(_ panel: AudioTrackPanel) {
        panel.stopPlayhead()
        panel.removeFromSuperview()
        trackPanels.removeAll { $0 === panel }
        updateCanvasHeight()

        if trackPanels.isEmpty {
            let ph = makePlaceholder()
            placeholderView = ph
            trackCanvas.addSubview(ph)
            NSLayoutConstraint.activate([
                ph.centerXAnchor.constraint(equalTo: trackCanvas.centerXAnchor),
                ph.centerYAnchor.constraint(equalTo: trackCanvas.centerYAnchor),
                ph.widthAnchor.constraint(equalToConstant: 380),
                ph.heightAnchor.constraint(equalToConstant: 120),
            ])
        }
    }

    private func updateCanvasHeight() {
        let minH = scrollView.contentView.bounds.height
        let maxBottom = trackPanels.map { $0.frame.maxY + 14 }.max() ?? minH
        canvasHeightConstraint.constant = max(minH, maxBottom)
    }

    // MARK: – Actions

    @objc func openDocument(_ sender: Any?) { openAudioFile() }
    @objc private func openFilePressed() { openAudioFile() }

    private func handleSpaceBar() {
        // Control the panel that owns the currently active (playing/paused) document
        if let doc = AudioEngine.shared.playingDocument,
           let panel = trackPanels.first(where: { $0.document === doc }) {
            panel.togglePlayPause()
            return
        }
        // Nothing playing: start the last focused (or first) panel
        (focusedPanel ?? trackPanels.first)?.togglePlayPause()
    }

    private func openAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Audio File"
        panel.allowedFileTypes = ["mp3", "wav", "aiff", "aif", "m4a", "caf"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.loadFile(url: url) }
        }
    }

    private func loadFile(url: URL) {
        do {
            let doc = AudioDocument()
            try doc.read(from: url, ofType: "")
            addTrackPanel(for: doc)
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window!, completionHandler: nil)
        }
    }

    @objc private func volumeChanged() {
        AudioEngine.shared.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func windowResized() {
        let padding: CGFloat = 14
        let w = max(400, scrollView.contentView.bounds.width - padding * 2)
        trackPanels.forEach { $0.frame.size.width = w }
        updateCanvasHeight()
    }
}
