import AppKit
import VoxBarberAudio

/// Hanghullám megjelenítő nézet.
///
/// Teljesítmény-stratégia:
///  - A peak-számítás (min/max pixel-oszloponként) `Task.detached` segítségével
///    háttérszálon fut, így nem blokkolja a main threaded.
///  - Az eredmény egy `CGImage`-be kerül, amelyet `draw()` egyetlen hívással
///    jelenít meg. Újraszámítás csak akkor történik, ha buffer / zoom / méret változik.
///  - Folyamatban lévő számítás mindig megszakad, ha új kérés érkezik.
@MainActor
final class WaveformView: NSView {

    // MARK: – Belső állapot

    private var currentBuffer:   VoxBarberAudio.AudioBuffer = .empty()
    private var currentZoom:     Double = 1.0
    private var scrollOffsetSec: Double = 0      // látható ablak kezdete (másodperc)
    private var storedSampleRate: Double = 44100
    private var storedFrameCount: Int    = 0
    private var cachedImage:        CGImage?
    private var cachedScrollOffset:  Double = 0      // melyik offsetre lett renderelve a cachedImage
    private var renderTask:          Task<Void, Never>?
    private var debounceTask:        Task<Void, Never>?
    private var cursorFrame:         Int = -1         // -1 = rejtett
    private var markerFrames:        [Int] = []       // jelölőpontok frame-pozíciói
    private var markerNames:         [String] = []    // jelölőpontok nevei (frame-ekkel azonos sorrendben)

    // Drag (panning) állapot
    private var dragAnchorX:      CGFloat = 0
    private var dragAnchorOffset: Double  = 0
    private var didDrag:          Bool    = false   // panning történt-e (vs. tiszta kattintás)

    /// Scroll-esemény értesítő: az új offset másodpercben.
    var onScrollOffsetChanged: ((Double) -> Void)?

    /// Kattintás-esemény értesítő: a kattintott pozíció frame-ben.
    /// Csak akkor hívódik, ha a felhasználó kattintott (nem húzott).
    var onSeek: ((Int) -> Void)?

    /// Az aktuális scroll offset (másodperc) – olvasható kívülről.
    var currentScrollOffset: Double { scrollOffsetSec }

    /// Beállítja a lejátszási kurzor frame-pozícióját. -1 = rejtett.
    func setCursorFrame(_ frame: Int) {
        cursorFrame  = frame
        needsDisplay = true
    }

    /// Beállítja a kirajzolandó jelölőpontok frame-pozícióit és neveit.
    func setMarkerFrames(_ frames: [Int], names: [String] = []) {
        markerFrames = frames
        markerNames  = names
        needsDisplay = true
    }

    // MARK: – Nyilvános API

    /// Betölti az új hangpuffert és újrarajzolja a waveformot.
    func setBuffer(_ buffer: VoxBarberAudio.AudioBuffer, zoom: Double? = nil) {
        currentBuffer     = buffer
        storedSampleRate  = buffer.sampleRate
        storedFrameCount  = buffer.frameCount
        if let z = zoom { currentZoom = z }
        clampScrollOffset()
        scheduleRender()
    }

    /// Zoom szintét frissíti, korlátozza a scroll offsetet, és újrarajzolja.
    func setZoom(_ zoom: Double) {
        let oldOffset = scrollOffsetSec
        currentZoom = zoom
        clampScrollOffset()
        scheduleRender()
        if scrollOffsetSec != oldOffset {
            onScrollOffsetChanged?(scrollOffsetSec)
        }
    }

    /// Scroll offset beállítása kívülről (callback nélkül – szinkronizáláshoz).
    /// Azonnali vizuális eltolás a cached képen; 80ms inaktivitás után teljes újrarender.
    func setScrollOffset(_ sec: Double) {
        scrollOffsetSec = sec
        needsDisplay = true
        scheduleDebouncedRender()
    }

    /// Elhalasztott render: 80ms inaktivitás után indít teljes újrarajzolást.
    private func scheduleDebouncedRender() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.scheduleRender()
        }
    }

    // MARK: – Scroll segédfüggvények

    private func clampScrollOffset() {
        guard storedSampleRate > 0, storedFrameCount > 0 else { scrollOffsetSec = 0; return }
        let totalDuration   = Double(storedFrameCount) / storedSampleRate
        let visibleDuration = totalDuration / max(1.0, currentZoom)
        let maxOffset       = max(0.0, totalDuration - visibleDuration)
        scrollOffsetSec     = max(0.0, min(scrollOffsetSec, maxOffset))
    }

    private func totalAndVisible() -> (total: Double, visible: Double, pixPerSec: Double)? {
        guard storedSampleRate > 0, storedFrameCount > 0, bounds.width > 1 else { return nil }
        let total   = Double(storedFrameCount) / storedSampleRate
        let visible = total / currentZoom
        let pps     = Double(bounds.width) / visible
        return (total, visible, pps)
    }

    // MARK: – Layout

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Csak akkor render, ha tényleg van méretünk
        if bounds.width > 1 && bounds.height > 1 {
            scheduleRender()
        }
    }

    // MARK: – Rajzolás

    // Ne használjunk Core Animation layer-alapú rajzolást – a draw() override
    // közvetlenül a CGContext-be ír, ez a megbízhatóbb NSView rajzolási mód.
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Háttér
        ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0))
        ctx.fill(bounds)
        if let img = cachedImage, let (_, visible, _) = totalAndVisible() {
            // Pixel-eltolás: a cached kép a cachedScrollOffset-re lett renderelve.
            // Ha azóta scrolloztunk, toljuk el a képet – azonnali, render nélkül.
            let pps        = Double(bounds.width) / visible
            let pixelShift = CGFloat((scrollOffsetSec - cachedScrollOffset) * pps)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: -pixelShift, y: 0,
                                     width: bounds.width, height: bounds.height))
            ctx.restoreGState()
        }
        // Jelölőpontok overlay (a kurzor alatt)
        drawMarkers(ctx: ctx)
        // Lejátszási kurzor overlay
        drawCursor(ctx: ctx)
    }

    /// Kirajzolja a jelölőpontokat feltűnő függőleges vonalakkal (a kurzortól
    /// eltérő színnel). Minden vonal a saját frame-pozíciójánál jelenik meg, ha
    /// a látható tartományba esik.
    private func drawMarkers(ctx: CGContext) {
        guard storedSampleRate > 0, storedFrameCount > 0, bounds.width > 1 else { return }
        let totalDuration   = Double(storedFrameCount) / storedSampleRate
        let visibleDuration = totalDuration / max(1.0, currentZoom)
        guard visibleDuration > 0 else { return }

        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.95, blue: 0.55, alpha: 0.95))
        ctx.setLineWidth(2.0)
        let markerColor = NSColor(red: 0.0, green: 0.95, blue: 0.55, alpha: 1.0)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: markerColor
        ]
        for (index, frame) in markerFrames.enumerated() {
            let sec    = Double(frame) / storedSampleRate
            let relSec = sec - scrollOffsetSec
            guard relSec >= 0, relSec <= visibleDuration else { continue }
            let x = CGFloat(relSec / visibleDuration) * bounds.width
            ctx.setStrokeColor(markerColor.cgColor)
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.strokePath()

            // Név a vonal mellett, a hanghullám tetején, kicsi betűkkel.
            if index < markerNames.count {
                let name = markerNames[index]
                if !name.isEmpty {
                    let attr = NSAttributedString(string: name, attributes: labelAttrs)
                    let textSize = attr.size()
                    // A vonaltól jobbra, de ha kilógna a jobb szélen, akkor balra.
                    var textX = x + 3
                    if textX + textSize.width > bounds.width {
                        textX = x - 3 - textSize.width
                    }
                    let textY: CGFloat = 2  // felül (flipped koordináta)
                    attr.draw(at: CGPoint(x: textX, y: textY))
                }
            }
        }
    }

    private func drawCursor(ctx: CGContext) {
        guard cursorFrame >= 0,
              storedSampleRate > 0,
              storedFrameCount > 0,
              bounds.width > 1 else { return }

        let totalDuration   = Double(storedFrameCount) / storedSampleRate
        let visibleDuration = totalDuration / max(1.0, currentZoom)
        let cursorSec       = Double(cursorFrame) / storedSampleRate
        let relSec          = cursorSec - scrollOffsetSec

        // Csak ha a látható tartományon belül van
        guard relSec >= 0, relSec <= visibleDuration else { return }

        let x = CGFloat(relSec / visibleDuration) * bounds.width

        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 0.95))
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: x, y: 0))
        ctx.addLine(to: CGPoint(x: x, y: bounds.height))
        ctx.strokePath()
    }

    // MARK: – Háttér-renderelés

    private func scheduleRender() {
        renderTask?.cancel()

        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        // Értéktípus-másolatok a háttérszál számára (data race-mentes)
        let samples      = currentBuffer.samples
        let channelCount = currentBuffer.channelCount
        let frameCount   = currentBuffer.frameCount
        let zoom         = currentZoom
        let scrollOffset = scrollOffsetSec
        let sampleRate   = storedSampleRate

        renderTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let image = Self.render(
                samples: samples,
                channelCount: channelCount,
                frameCount: frameCount,
                zoom: zoom,
                scrollOffset: scrollOffset,
                sampleRate: sampleRate,
                size: size
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedImage = image
                self.cachedScrollOffset = scrollOffset  // feljegyezzük, melyik offsetre szól
                self.needsDisplay = true
            }
        }
    }

    // MARK: – Statikus renderelő (háttérszálon fut)

    // MARK: – Egér (panning)

    override func mouseDown(with event: NSEvent) {
        // Fokusz + előtér kezelés a szülőpanelnek
        nextResponder?.mouseDown(with: event)
        didDrag = false
        let loc = convert(event.locationInWindow, from: nil)
        dragAnchorX      = loc.x
        dragAnchorOffset = scrollOffsetSec
        if currentZoom > 1.0 {
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard currentZoom > 1.0,
              let (total, visible, pps) = totalAndVisible() else {
            super.mouseDragged(with: event)
            return
        }
        let loc        = convert(event.locationInWindow, from: nil)
        // Drag-küszöb: 3px-nél nagyobb elmozdulás már panningnek számít
        if abs(loc.x - dragAnchorX) > 3 { didDrag = true }
        let deltaPixels = Double(loc.x - dragAnchorX)
        // Jobbra húzás = korábbi rész felé görgetés (offset csökken)
        let deltaSec   = -deltaPixels / pps
        let maxOffset  = max(0.0, total - visible)
        let newOffset  = max(0.0, min(dragAnchorOffset + deltaSec, maxOffset))
        if newOffset != scrollOffsetSec {
            scrollOffsetSec = newOffset
            needsDisplay = true                  // azonnali pixel-shift, render nélkül
            scheduleDebouncedRender()            // teljes render csak 80ms inaktivitás után
            onScrollOffsetChanged?(scrollOffsetSec)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if currentZoom > 1.0 { NSCursor.pop() }
        // Tiszta kattintás (nem panning) → seek a kattintott pozícióra
        if !didDrag {
            let loc = convert(event.locationInWindow, from: nil)
            if let frame = frameAt(x: loc.x) {
                onSeek?(frame)
            }
        } else {
            // Drag vége: azonnal pontos render, ne kelljen várni a debounce-ra
            debounceTask?.cancel()
            scheduleRender()
        }
        super.mouseUp(with: event)
    }

    /// A nézet x-koordinátájához tartozó frame-pozíciót adja vissza (teljes pufferben).
    private func frameAt(x: CGFloat) -> Int? {
        guard storedSampleRate > 0, storedFrameCount > 0, bounds.width > 1 else { return nil }
        let totalDuration   = Double(storedFrameCount) / storedSampleRate
        let visibleDuration = totalDuration / max(1.0, currentZoom)
        let clampedX        = max(0, min(bounds.width, x))
        let sec             = scrollOffsetSec + Double(clampedX / bounds.width) * visibleDuration
        let frame           = Int(sec * storedSampleRate)
        return max(0, min(storedFrameCount, frame))
    }

    override func resetCursorRects() {
        if currentZoom > 1.0 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    // MARK: – Statikus renderelő (háttérszálon fut)

    nonisolated private static func render(
        samples:      [Float],
        channelCount: Int,
        frameCount:   Int,
        zoom:         Double,
        scrollOffset: Double,
        sampleRate:   Double,
        size:         CGSize
    ) -> CGImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 0, h > 0 else { return nil }

        // CGContext létrehozása (BGRA, premultiplied alpha)
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // Háttér
        ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Közép-vonal
        let midY = Double(h) / 2.0
        ctx.setStrokeColor(CGColor(red: 0.28, green: 0.28, blue: 0.32, alpha: 1.0))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: Double(0), y: midY))
        ctx.addLine(to: CGPoint(x: Double(w), y: midY))
        ctx.strokePath()

        guard frameCount > 0, channelCount > 0 else { return ctx.makeImage() }

        let safeChannels     = max(1, channelCount)
        let scrollFrames     = Int(scrollOffset * max(1.0, sampleRate))
        let visibleFrames    = Double(frameCount) / max(1.0, zoom)
        let framesPerPixel   = max(1.0, visibleFrames / Double(w))

        // Waveform szín
        ctx.setFillColor(CGColor(red: 0.25, green: 0.65, blue: 1.0, alpha: 0.85))

        for col in 0..<w {
            if Task.isCancelled { return nil }

            let startFrame = min(max(0, frameCount - 1), scrollFrames + Int(Double(col) * framesPerPixel))
            let endFrame   = min(frameCount, max(startFrame + 1, scrollFrames + Int(Double(col + 1) * framesPerPixel)))

            var mn: Float =  0.0
            var mx: Float =  0.0

            for frame in startFrame..<endFrame {
                var sum: Float = 0
                for ch in 0..<safeChannels {
                    let idx = frame * safeChannels + ch
                    if idx < samples.count { sum += samples[idx] }
                }
                let avg = sum / Float(safeChannels)
                if avg < mn { mn = avg }
                if avg > mx { mx = avg }
            }

            // A CG-koordinátarendszer y=0 = alul → a waveform sáv pozíciója:
            let top  = midY - Double(mx) * midY
            let bot  = midY - Double(mn) * midY
            let barH = max(1.0, bot - top)
            ctx.fill(CGRect(x: Double(col), y: top, width: 1.0, height: barH))
        }

        return ctx.makeImage()
    }
}
