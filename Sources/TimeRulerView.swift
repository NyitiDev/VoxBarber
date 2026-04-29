import AppKit

/// Horizontal time ruler that shows millisecond / second markers in sync
/// with the waveform's current zoom level and scroll position.
final class TimeRulerView: NSView {

    // MARK: Public properties (set by AudioTrackPanel)

    var samplesPerPixel: Double = 512 { didSet { needsDisplay = true } }
    var scrollOffset: CGFloat   = 0   { didSet { needsDisplay = true } }
    var sampleRate: Double      = 44100 { didSet { needsDisplay = true } }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor)
        ctx.fill(bounds)

        // Top separator line
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: bounds.height - 0.5))
        ctx.addLine(to: CGPoint(x: bounds.width, y: bounds.height - 0.5))
        ctx.strokePath()

        let width  = bounds.width
        let height = bounds.height

        // ms per pixel at current zoom
        let msPerPixel = samplesPerPixel / (sampleRate / 1000.0)

        // Choose tick intervals based on density
        let (majorMs, minorMs): (Double, Double)
        switch msPerPixel {
        case ..<0.04:  majorMs = 10;     minorMs = 2
        case ..<0.2:   majorMs = 50;     minorMs = 10
        case ..<0.8:   majorMs = 100;    minorMs = 20
        case ..<4:     majorMs = 500;    minorMs = 100
        case ..<20:    majorMs = 1_000;  minorMs = 200
        case ..<100:   majorMs = 5_000;  minorMs = 1_000
        default:       majorMs = 10_000; minorMs = 2_000
        }

        // Visible time range in ms
        let startMs = Double(scrollOffset) * msPerPixel
        let endMs   = startMs + Double(width) * msPerPixel

        // First tick at or before startMs (aligned to minorMs grid)
        let firstMs = floor(startMs / minorMs) * minorMs

        var ms = firstMs
        while ms <= endMs + minorMs {
            let x = CGFloat((ms - startMs) / msPerPixel)
            guard x >= -1 && x <= width + 1 else { ms += minorMs; continue }

            let isMajor = ms.truncatingRemainder(dividingBy: majorMs) < (minorMs * 0.5)

            let tickH: CGFloat = isMajor ? height * 0.6 : height * 0.35
            let alpha: CGFloat = isMajor ? 0.35 : 0.15
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: tickH))
            ctx.strokePath()

            if isMajor {
                let label: String
                if ms >= 60_000 {
                    let min = Int(ms) / 60_000
                    let sec = ms.truncatingRemainder(dividingBy: 60_000) / 1000.0
                    label = String(format: "%d:%04.1f", min, sec)
                } else if ms >= 1_000 {
                    label = String(format: "%.2fs", ms / 1000.0)
                } else {
                    label = String(format: "%.0fms", ms)
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.42)
                ]
                let astr = NSAttributedString(string: label, attributes: attrs)
                let labelWidth = astr.size().width
                // Clamp so label doesn't spill off right edge
                let labelX = min(x + 2, width - labelWidth - 1)
                astr.draw(at: CGPoint(x: labelX, y: (height - 9) / 2))
            }

            ms += minorMs
        }
    }
}
