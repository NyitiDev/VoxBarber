import AppKit

/// Időskála nézet a waveform ablak alján.
///
/// Adaptívan választja meg a tick-intervallumot a zoom alapján:
/// kicsinyítve másodpercek/percek látszanak, nagyítva ezredmásodpercek is.
final class TimeRulerView: NSView {

    // MARK: – Állapot

    private var sampleRate:   Double = 44100
    private var frameCount:   Int    = 0
    private var zoom:         Double = 1.0
    private var scrollOffset: Double = 0  // látható ablak kezdete, másodpercben

    // Jelölt intervallumok növekvő sorrendben (másodperc)
    private static let candidates: [Double] = [
        0.0001, 0.0002, 0.0005,                     // 0.1ms – 0.5ms
        0.001,  0.002,  0.005,                       // 1ms   – 5ms
        0.01,   0.02,   0.05,                        // 10ms  – 50ms
        0.1,    0.2,    0.5,                         // 100ms – 500ms
        1,      2,      5,      10,   15,   30,      // 1s    – 30s
        60,     120,    300,    600,  1800, 3600      // 1min  – 1h
    ]

    // MARK: – Nyilvános API

    func configure(sampleRate: Double, frameCount: Int, zoom: Double, scrollOffset: Double = 0) {
        self.sampleRate   = sampleRate
        self.frameCount   = frameCount
        self.zoom         = zoom
        self.scrollOffset = scrollOffset
        needsDisplay      = true
    }

    func setZoom(_ zoom: Double) {
        self.zoom    = zoom
        needsDisplay = true
    }

    func setScrollOffset(_ sec: Double) {
        scrollOffset = sec
        needsDisplay = true
    }

    // MARK: – NSView

    override var isFlipped: Bool    { true  }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let w = Double(bounds.width)

        // Háttér
        ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0))
        ctx.fill(bounds)

        // Felső elválasztó
        ctx.setStrokeColor(CGColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0,   y: 0.25))
        ctx.addLine(to: CGPoint(x: w, y: 0.25))
        ctx.strokePath()

        guard frameCount > 0, sampleRate > 0, w > 1 else { return }

        let totalDuration   = Double(frameCount) / sampleRate
        let visibleDuration = totalDuration / zoom
        let pixelsPerSec    = w / visibleDuration

        // Legkisebb intervallum, ahol a tickek között >= 50 px van
        let interval = Self.candidates.first { $0 * pixelsPerSec >= 50 }
                       ?? Self.candidates.last!

        // Tick + label rajzolás
        ctx.setStrokeColor(CGColor(red: 0.50, green: 0.50, blue: 0.55, alpha: 1.0))
        ctx.setLineWidth(0.5)

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
        ]

        // Csak a látható tartományban lévő tick-ektől számoljuk
        let firstTickIdx = max(0, Int(floor(scrollOffset / interval)))
        let endTime      = scrollOffset + visibleDuration

        var idx = firstTickIdx
        while true {
            let t = Double(idx) * interval
            if t > endTime + interval / 2 { break }

            let x = CGFloat((t - scrollOffset) * pixelsPerSec)
            if x >= -1 && x <= CGFloat(w) + 1 {
                let isMajor = idx % 5 == 0
                let tickH: CGFloat = isMajor ? 8 : 4

                ctx.move(to: CGPoint(x: x, y: 1))
                ctx.addLine(to: CGPoint(x: x, y: 1 + tickH))
                ctx.strokePath()

                if isMajor {
                    let label = Self.formatTime(seconds: t, interval: interval)
                    let str   = NSAttributedString(string: label, attributes: attrs)
                    let size  = str.size()

                    var lx = x + 3
                    if lx + size.width > CGFloat(w) { lx = x - size.width - 2 }
                    if lx < 2 { lx = 2 }
                    str.draw(at: CGPoint(x: lx, y: 1 + tickH + 2))
                }
            }

            idx += 1
        }
    }

    // MARK: – Időformázás

    private static func formatTime(seconds t: Double, interval: Double) -> String {
        if interval < 1.0 {
            let ms = t * 1000.0
            if interval < 0.001 {
                return String(format: "%.1fms", ms)
            } else {
                return String(format: "%.0fms", ms)
            }
        } else {
            let totalS = Int(round(t))
            let m = totalS / 60
            let s = totalS % 60
            return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
        }
    }
}
