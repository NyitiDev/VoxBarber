import AppKit
import AVFoundation

/// A draggable "mini window" view inside the hub window's canvas.
/// Title bar: close dot | filename ... | play pause stop | cut copy paste
final class AudioTrackPanel: NSView {

    // MARK: Public

    let document: AudioDocument
    var onClose: (() -> Void)?
    /// Called after the panel is dragged so the canvas can update its height.
    var onFrameChange: (() -> Void)?

    let timelineScrollView = TimelineScrollView()

    // MARK: Private – views

    private let rulerView  = TimeRulerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeBtn   = NSButton()
    // Title-bar action buttons (small, 24×24)
    private let playBtn  = IconButton(symbol: "play.fill",        tip: "Play",  size: 11, buttonSize: 24)
    private let pauseBtn = IconButton(symbol: "pause.fill",       tip: "Pause", size: 11, buttonSize: 24)
    private let stopBtn  = IconButton(symbol: "stop.fill",        tip: "Stop",  size: 11, buttonSize: 24)
    private let cutBtn   = IconButton(symbol: "scissors",          tip: "Cut",     size: 11, buttonSize: 24)
    private let copyBtn  = IconButton(symbol: "doc.on.doc",       tip: "Copy",    size: 11, buttonSize: 24)
    private let pasteBtn = IconButton(symbol: "doc.on.clipboard", tip: "Paste",   size: 11, buttonSize: 24)
    private let zoomInBtn  = IconButton(symbol: "plus.magnifyingglass",  tip: "Zoom In",  size: 11, buttonSize: 24)
    private let zoomOutBtn = IconButton(symbol: "minus.magnifyingglass", tip: "Zoom Out", size: 11, buttonSize: 24)

    // MARK: Private – resize

    private var isResizing        = false
    private var resizeStartScreen = NSPoint.zero
    private var resizeStartSize   = NSSize.zero
    private let resizeZone: CGFloat = 12   // px from bottom-right corner

    private var isDragging       = false
    private var dragStartScreen  = NSPoint.zero
    private var dragStartOrigin  = NSPoint.zero

    // MARK: Private – playback

    private var playbackTimer:    Timer?
    private var pendingSeekSample: Int? = nil   // used when stopped and user clicks to seek

    // MARK: Constants

    private let titleH: CGFloat = 36
    private let rulerH: CGFloat = 22

    // MARK: Init

    init(document: AudioDocument) {
        self.document = document
        super.init(frame: .zero)
        build()
        loadContent()
        setupScrollSync()
        NotificationCenter.default.addObserver(
            self, selector: #selector(bufferChanged),
            name: .audioDocumentBufferDidChange, object: document)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        playbackTimer?.invalidate()
    }

    // Flipped so Y=0 is the visual top (matches title-bar hit-test logic)
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timelineScrollView.reloadWaveform(buffer: self.document.buffer)
            self.syncRuler()
            // Fit the full file into the visible width on first open
            self.timelineScrollView.fitToWidth()
        }
    }

    // MARK: – Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = AppColors.surface.cgColor
        layer?.cornerRadius    = 10
        layer?.borderColor     = NSColor.white.withAlphaComponent(0.09).cgColor
        layer?.borderWidth     = 1

        // ── Title bar ──────────────────────────────────────────────────
        let titleBar = NSView()
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        addSubview(titleBar)

        // Traffic-light close dot
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.isBordered = false
        closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor =
            NSColor(srgbRed: 0.98, green: 0.37, blue: 0.35, alpha: 1).cgColor
        closeBtn.layer?.cornerRadius = 6
        closeBtn.title  = ""
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        titleBar.addSubview(closeBtn)

        // Filename label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font      = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        titleBar.addSubview(titleLabel)

        // Right-side action buttons (right → left order in constraints)
        let rightBtns: [NSView] = [zoomOutBtn, zoomInBtn, pasteBtn, copyBtn, cutBtn, stopBtn, pauseBtn, playBtn]
        for btn in rightBtns { titleBar.addSubview(btn) }
        playBtn.target   = self; playBtn.action   = #selector(playTapped)
        pauseBtn.target  = self; pauseBtn.action  = #selector(pauseTapped)
        stopBtn.target   = self; stopBtn.action   = #selector(stopTapped)
        cutBtn.target    = self; cutBtn.action    = #selector(cutTapped)
        copyBtn.target   = self; copyBtn.action   = #selector(copyTapped)
        pasteBtn.target  = self; pasteBtn.action  = #selector(pasteTapped)
        zoomInBtn.target  = self; zoomInBtn.action  = #selector(zoomInTapped)
        zoomOutBtn.target = self; zoomOutBtn.action = #selector(zoomOutTapped)

        // ── Waveform & ruler ───────────────────────────────────────────
        timelineScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timelineScrollView)
        rulerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rulerView)

        // ── Constraints ────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: titleH),

            closeBtn.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 12),
            closeBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 12),
            closeBtn.heightAnchor.constraint(equalToConstant: 12),

            titleLabel.leadingAnchor.constraint(equalTo: closeBtn.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: playBtn.leadingAnchor,
                                                  constant: -8),

            // Buttons right → left
            zoomOutBtn.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -8),
            zoomOutBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            zoomInBtn.trailingAnchor.constraint(equalTo: zoomOutBtn.leadingAnchor, constant: -2),
            zoomInBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            pasteBtn.trailingAnchor.constraint(equalTo: zoomInBtn.leadingAnchor, constant: -8),
            pasteBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            copyBtn.trailingAnchor.constraint(equalTo: pasteBtn.leadingAnchor, constant: -2),
            copyBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            cutBtn.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -2),
            cutBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            stopBtn.trailingAnchor.constraint(equalTo: cutBtn.leadingAnchor, constant: -8),
            stopBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            pauseBtn.trailingAnchor.constraint(equalTo: stopBtn.leadingAnchor, constant: -2),
            pauseBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            playBtn.trailingAnchor.constraint(equalTo: pauseBtn.leadingAnchor, constant: -2),
            playBtn.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            timelineScrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            timelineScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            timelineScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            timelineScrollView.bottomAnchor.constraint(equalTo: rulerView.topAnchor),

            rulerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rulerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rulerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rulerView.heightAnchor.constraint(equalToConstant: rulerH),
        ])
    }

    // MARK: – Content

    private func loadContent() {
        titleLabel.stringValue = document.fileName
        timelineScrollView.reloadWaveform(buffer: document.buffer)
        syncRuler()
        timelineScrollView.waveformView.samplesPerPixelChanged = { [weak self] spp in
            self?.rulerView.samplesPerPixel = spp
        }
        timelineScrollView.waveformView.seekRequested = { [weak self] sample in
            guard let self = self, let buf = self.document.buffer else { return }
            // Show cursor immediately regardless of playback state
            self.timelineScrollView.waveformView.playheadSample = sample
            if AudioEngine.shared.isPlaying || AudioEngine.shared.isPaused {
                if AudioEngine.shared.playingDocument === self.document {
                    AudioEngine.shared.seek(toSample: sample, in: buf, document: self.document)
                    if AudioEngine.shared.isPlaying { self.startPlayhead() }
                    // if paused: stay paused at new position
                }
            } else {
                // Stopped: remember position so next Play starts from here
                self.pendingSeekSample = sample
            }
        }
    }

    private func setupScrollSync() {
        timelineScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: timelineScrollView.contentView)
    }

    private func syncRuler() {
        if let buf = document.buffer {
            rulerView.sampleRate = buf.format.sampleRate
        }
        rulerView.samplesPerPixel = timelineScrollView.waveformView.samplesPerPixel
        rulerView.scrollOffset    = timelineScrollView.contentView.bounds.origin.x
    }

    // MARK: – Draw (resize grip)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw 3 diagonal lines in bottom-right corner as resize grip
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let color = NSColor.white.withAlphaComponent(0.20)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        for i: CGFloat in [4, 8, 12] {
            ctx.move(to: CGPoint(x: b.maxX - i, y: b.maxY))
            ctx.addLine(to: CGPoint(x: b.maxX, y: b.maxY - i))
        }
        ctx.strokePath()
    }

    // MARK: – Playhead

    func startPlayhead() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard AudioEngine.shared.playingDocument === self.document else {
                self.stopPlayhead(); return
            }
            self.timelineScrollView.waveformView.playheadSample =
                AudioEngine.shared.currentPlaybackSample
            if !AudioEngine.shared.isPlaying && !AudioEngine.shared.isPaused {
                self.stopPlayhead()
            }
        }
    }

    /// Freeze cursor at current position (used after pause).
    func pausePlayhead() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        // Leave playheadSample at last drawn position
    }

    func stopPlayhead() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        timelineScrollView.waveformView.playheadSample = nil
    }

    // MARK: – Actions

    @objc private func closeTapped() { onClose?() }

    /// Called externally (e.g. space bar) to toggle play/pause for this panel.
    func togglePlayPause() {
        if AudioEngine.shared.isPlaying && AudioEngine.shared.playingDocument === document {
            AudioEngine.shared.pause()
            pausePlayhead()
        } else if AudioEngine.shared.isPaused && AudioEngine.shared.playingDocument === document {
            AudioEngine.shared.resume()
            startPlayhead()
        } else {
            playTapped()
        }
    }

    @objc private func playTapped() {
        guard let buf = document.buffer else { return }
        if AudioEngine.shared.isPaused && AudioEngine.shared.playingDocument === document {
            AudioEngine.shared.resume()
            startPlayhead()
        } else {
            // Use pending seek position if the user clicked to seek while stopped
            let startSample = pendingSeekSample
            pendingSeekSample = nil
            let seekSel: ClosedRange<Int>? = startSample.map { $0...(Int(buf.frameLength) - 1) }
            AudioEngine.shared.play(buffer: buf,
                                    selection: seekSel ?? timelineScrollView.waveformView.selection,
                                    document: document)
            startPlayhead()
        }
    }

    @objc private func pauseTapped() {
        guard AudioEngine.shared.playingDocument === document else { return }
        if AudioEngine.shared.isPlaying {
            AudioEngine.shared.pause()
            pausePlayhead()
        } else if AudioEngine.shared.isPaused {
            AudioEngine.shared.resume()
            startPlayhead()
        }
    }

    @objc private func stopTapped() {
        AudioEngine.shared.stop()
        stopPlayhead()
    }

    @objc private func cutTapped() {
        guard let buf = document.buffer,
              let sel = timelineScrollView.waveformView.selection,
              let (modified, excised) = EditOperations.cut(from: buf, range: sel) else { return }
        EditOperations.writeToPasteboard(excised)
        document.replaceBuffer(with: modified)
    }

    @objc private func copyTapped() {
        guard let buf = document.buffer,
              let sel = timelineScrollView.waveformView.selection,
              let segment = EditOperations.copy(from: buf, range: sel) else { return }
        EditOperations.writeToPasteboard(segment)
    }

    @objc private func pasteTapped() {
        guard let buf = document.buffer,
              let segment = EditOperations.readFromPasteboard(expectedFormat: buf.format)
        else { return }
        let at = timelineScrollView.waveformView.selection?.lowerBound ?? Int(buf.frameLength)
        guard let result = EditOperations.paste(segment: segment, into: buf, at: at) else { return }
        document.replaceBuffer(with: result)
    }

    // MARK: – Notifications

    @objc private func bufferChanged() {
        timelineScrollView.reloadWaveform(buffer: document.buffer)
        syncRuler()
    }

    @objc private func scrollBoundsChanged() {
        rulerView.scrollOffset = timelineScrollView.contentView.bounds.origin.x
    }

    // MARK: – Zoom

    @objc private func zoomInTapped() {
        timelineScrollView.waveformView.samplesPerPixel /= 1.6
    }

    @objc private func zoomOutTapped() {
        // Clamp so we never zoom out past fit-to-width
        timelineScrollView.waveformView.samplesPerPixel *= 1.6
        if let buf = document.buffer, buf.frameLength > 0 {
            let visibleW = timelineScrollView.contentView.bounds.width
            let fitSpp   = Double(buf.frameLength) / max(1, Double(visibleW))
            if timelineScrollView.waveformView.samplesPerPixel > fitSpp {
                timelineScrollView.waveformView.samplesPerPixel = fitSpp
            }
        }
    }

    // MARK: – Resize handle (bottom-right corner)

    private func inResizeZone(_ loc: NSPoint) -> Bool {
        // isFlipped=true: bottom edge is at y == frame.height
        let b = bounds
        return loc.x > b.maxX - resizeZone && loc.y > b.maxY - resizeZone
    }

    override func resetCursorRects() {
        let b = bounds
        let resizeRect = CGRect(x: b.maxX - resizeZone, y: b.maxY - resizeZone,
                                width: resizeZone, height: resizeZone)
        addCursorRect(resizeRect, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if inResizeZone(loc) {
            isResizing        = true
            resizeStartScreen = NSEvent.mouseLocation
            resizeStartSize   = frame.size
            return
        }
        // Title-bar drag
        guard loc.y < titleH else { return }
        let buttons: [NSView] = [closeBtn, playBtn, pauseBtn, stopBtn, cutBtn, copyBtn, pasteBtn, zoomInBtn, zoomOutBtn]
        let onButton = buttons.contains { btn in
            convert(btn.frame, from: btn.superview).contains(loc)
        }
        guard !onButton else { return }
        isDragging      = true
        dragStartScreen = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            let cur = NSEvent.mouseLocation
            let dx  =  cur.x - resizeStartScreen.x
            let dy  = -(cur.y - resizeStartScreen.y)   // flipped
            let newW = max(320, resizeStartSize.width  + dx)
            let newH = max(120, resizeStartSize.height + dy)
            frame.size = NSSize(width: newW, height: newH)
            onFrameChange?()
            return
        }
        guard isDragging else { super.mouseDragged(with: event); return }
        let cur = NSEvent.mouseLocation
        let dx  =   cur.x - dragStartScreen.x
        let dy  = -(cur.y - dragStartScreen.y)
        frame.origin = NSPoint(
            x: max(0, dragStartOrigin.x + dx),
            y: max(0, dragStartOrigin.y + dy)
        )
        onFrameChange?()
    }

    override func mouseUp(with event: NSEvent) {
        isResizing = false
        isDragging = false
        super.mouseUp(with: event)
    }
}
