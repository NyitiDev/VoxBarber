import AppKit
import AVFoundation
import Accelerate

// MARK: - WaveformView

/// Draws the waveform of an AVAudioPCMBuffer, supports zoom and drag-selection.
final class WaveformView: NSView {

    // MARK: Public interface

    var buffer: AVAudioPCMBuffer? {
        didSet { rebuildWaveformData(); needsDisplay = true }
    }

    /// Zoom: samples per pixel.  Lower = more zoomed in.
    var samplesPerPixel: Double = 512 {
        didSet {
            samplesPerPixel = max(1, samplesPerPixel)
            samplesPerPixelChanged?(samplesPerPixel)
            rebuildWaveformData()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Currently selected sample range.  Observers may watch selectionDidChange.
    var selection: ClosedRange<Int>? {
        didSet { needsDisplay = true }
    }

    /// Callback fired whenever the selection changes.
    var selectionDidChange: ((ClosedRange<Int>?) -> Void)?

    /// Callback fired when samplesPerPixel (zoom level) changes.
    var samplesPerPixelChanged: ((Double) -> Void)?

    /// Callback fired when user single-clicks (no drag) on the waveform to seek.
    var seekRequested: ((Int) -> Void)?

    /// Current playback position in samples; draws a vertical cursor line when set.
    var playheadSample: Int? {
        didSet { needsDisplay = true }
    }

    // MARK: Private

    /// Pre-computed min/max pairs, one per rendered pixel column.
    private var waveformMin: [Float] = []
    private var waveformMax: [Float] = []

    private var dragStart: Int?
    private var hasDragged = false

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = AppColors.surface.cgColor
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: Layout

    override var intrinsicContentSize: NSSize {
        let columns = waveformMin.isEmpty ? 100 : waveformMin.count
        return NSSize(width: columns, height: 0) // height managed by superview
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(AppColors.surface.cgColor)
        ctx.fill(bounds)

        // Centre line
        let midY = bounds.midY
        ctx.setStrokeColor(AppColors.separator.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: midY))
        ctx.addLine(to: CGPoint(x: bounds.width, y: midY))
        ctx.strokePath()

        guard !waveformMin.isEmpty else { return }

        let totalColumns = waveformMin.count
        let height = bounds.height

        // Selection highlight
        if let sel = selection {
            let selStartPx = sampleToPx(sel.lowerBound)
            let selEndPx   = sampleToPx(sel.upperBound)
            ctx.setFillColor(AppColors.selection.cgColor)
            ctx.fill(CGRect(x: selStartPx, y: 0, width: selEndPx - selStartPx, height: height))

            // Selection border lines
            ctx.setStrokeColor(AppColors.accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: selStartPx, y: 0))
            ctx.addLine(to: CGPoint(x: selStartPx, y: height))
            ctx.move(to: CGPoint(x: selEndPx, y: 0))
            ctx.addLine(to: CGPoint(x: selEndPx, y: height))
            ctx.strokePath()
        }

        // Waveform bars
        ctx.setFillColor(AppColors.accent.cgColor)
        for col in 0 ..< totalColumns {
            let x = CGFloat(col)
            let mn = CGFloat(waveformMin[col])
            let mx = CGFloat(waveformMax[col])
            let yLow  = midY + mn * midY * 0.9
            let yHigh = midY + mx * midY * 0.9
            let barHeight = max(1, yHigh - yLow)
            ctx.fill(CGRect(x: x, y: yLow, width: 1, height: barHeight))
        }

        // Playhead cursor (drawn on top of everything)
        if let ph = playheadSample {
            let x = sampleToPx(ph)
            if x >= 0 && x <= bounds.width {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: height))
                ctx.strokePath()
                // Small triangle at top indicating playhead
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.move(to: CGPoint(x: x - 5, y: height))
                ctx.addLine(to: CGPoint(x: x + 5, y: height))
                ctx.addLine(to: CGPoint(x: x, y: height - 8))
                ctx.fillPath()
            }
        }
    }

    // MARK: Waveform data

    private func rebuildWaveformData() {
        waveformMin = []
        waveformMax = []

        guard let buf = buffer,
              buf.frameLength > 0,
              let floatData = buf.floatChannelData else { return }

        let frameCount = Int(buf.frameLength)
        let channelCount = Int(buf.format.channelCount)
        let spp = max(1, Int(samplesPerPixel))
        let columns = (frameCount + spp - 1) / spp

        // Mix down all channels to mono for display
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0 ..< channelCount {
            let ptr = floatData[ch]
            vDSP_vadd(mono, 1, ptr, 1, &mono, 1, vDSP_Length(frameCount))
        }
        if channelCount > 1 {
            var scale = Float(1) / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
        }

        var mins = [Float](repeating: 0, count: columns)
        var maxs = [Float](repeating: 0, count: columns)

        for col in 0 ..< columns {
            let start = col * spp
            let end   = min(start + spp, frameCount)
            let len   = vDSP_Length(end - start)
            var mn: Float = 0
            var mx: Float = 0
            mono.withUnsafeBufferPointer { ptr in
                vDSP_minv(ptr.baseAddress! + start, 1, &mn, len)
                vDSP_maxv(ptr.baseAddress! + start, 1, &mx, len)
            }
            mins[col] = mn
            maxs[col] = mx
        }
        waveformMin = mins
        waveformMax = maxs
    }

    // MARK: Coordinate helpers

    private func sampleToPx(_ sample: Int) -> CGFloat {
        guard let buf = buffer, buf.frameLength > 0 else { return 0 }
        return CGFloat(sample) / samplesPerPixel
    }

    private func pxToSample(_ px: CGFloat) -> Int {
        guard let buf = buffer else { return 0 }
        return min(max(0, Int(px * samplesPerPixel)), Int(buf.frameLength) - 1)
    }

    // MARK: Mouse events (selection)

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragStart  = pxToSample(loc.x)
        hasDragged = false
        selection  = nil
        selectionDidChange?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let current = pxToSample(loc.x)
        let lo = min(start, current)
        let hi = max(start, current)
        if lo < hi {
            hasDragged = true
            selection = lo...hi
            selectionDidChange?(selection)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !hasDragged, let sample = dragStart {
            seekRequested?(sample)
        }
        dragStart  = nil
        hasDragged = false
    }

    // MARK: Scroll wheel zoom

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // Cmd+scroll → zoom
            let factor = event.scrollingDeltaY > 0 ? 0.75 : 1.33
            samplesPerPixel *= factor
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - TimelineScrollView

/// Wraps a WaveformView inside an NSScrollView.
final class TimelineScrollView: NSScrollView {

    let waveformView = WaveformView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        backgroundColor = AppColors.surface
        documentView = waveformView
        waveformView.autoresizingMask = []
    }

    /// Called after the waveform is loaded so the scroll view updates its content size.
    func reloadWaveform(buffer: AVAudioPCMBuffer?) {
        waveformView.buffer = buffer
        let h = max(1, contentView.bounds.height)
        if let buf = buffer {
            let columns = max(100, Int(buf.frameLength) / max(1, Int(waveformView.samplesPerPixel)))
            waveformView.frame = CGRect(x: 0, y: 0, width: CGFloat(columns), height: h)
        } else {
            waveformView.frame = CGRect(x: 0, y: 0, width: 100, height: h)
        }
    }

    /// Set zoom so the entire file fits exactly inside the visible width.
    func fitToWidth() {
        guard let buf = waveformView.buffer, buf.frameLength > 0 else { return }
        let visibleW = contentView.bounds.width
        guard visibleW > 1 else { return }
        let spp = max(1.0, Double(buf.frameLength) / Double(visibleW))
        waveformView.samplesPerPixel = spp   // triggers samplesPerPixelChanged + layout
    }

    /// Keep waveform height in sync with the visible area after every layout pass.
    override func layout() {
        super.layout()
        let h = contentView.bounds.height
        guard h > 1 else { return }
        // Re-run full reload if height has changed (e.g. first real layout)
        if abs(waveformView.frame.height - h) > 1 {
            reloadWaveform(buffer: waveformView.buffer)
        }
    }
}
