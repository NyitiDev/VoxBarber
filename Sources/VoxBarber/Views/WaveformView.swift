import AppKit
import VoxBarberAudio

/// Egy szín-stop a hanghullám szakaszos színezéséhez: a `frame` pozíciótól
/// kezdve (a következő stopig) a megadott RGBA színnel rajzoljuk a hullámot.
struct WaveformColorStop: Sendable {
    let frame: Int
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat
}

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
    private var colorStops:          [WaveformColorStop] = []  // szakaszos hullámszínezés (frame szerint rendezve)

    // Drag (panning) állapot
    private var dragAnchorX:      CGFloat = 0
    private var dragAnchorOffset: Double  = 0
    private var didDrag:          Bool    = false   // panning történt-e (vs. tiszta kattintás)

    // Kijelölés (jobb egérgomb) állapot – frame-pozíciók a teljes pufferben
    private var selectionStart:   Int?    = nil
    private var selectionEnd:     Int?    = nil
    private var isSelecting:      Bool    = false
    private var selectionAnchor:  Int     = 0
    private var lastRightClickTime: TimeInterval = 0
    private var lastRightClickX: CGFloat? = nil

    /// Scroll-esemény értesítő: az új offset másodpercben.
    var onScrollOffsetChanged: ((Double) -> Void)?

    /// Kattintás-esemény értesítő: a kattintott pozíció frame-ben.
    /// Csak akkor hívódik, ha a felhasználó kattintott (nem húzott).
    var onSeek: ((Int) -> Void)?

    /// Kijelölés-változás értesítő: a kijelölt tartomány (start, end) frame-ben,
    /// vagy nil, ha a kijelölés megszűnt.
    var onSelectionChanged: (((start: Int, end: Int)?) -> Void)?

    /// Az aktuális scroll offset (másodperc) – olvasható kívülről.
    var currentScrollOffset: Double { scrollOffsetSec }

    /// Beállítja a lejátszási kurzor frame-pozícióját. -1 = rejtett.
    func setCursorFrame(_ frame: Int) {
        cursorFrame  = frame
        needsDisplay = true
    }

    /// Beállítja a kirajzolandó jelölőpontok frame-pozícióit és neveit.
    /// A `colors` (ha a frame-ekkel azonos hosszú) megadja, hogy az egyes
    /// jelölőpontoktól kezdve milyen színnel rajzoljuk a hanghullámot.
    func setMarkerFrames(_ frames: [Int],
                         names: [String] = [],
                         colors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []) {
        markerFrames = frames
        markerNames  = names
        if colors.count == frames.count {
            colorStops = zip(frames, colors)
                .map { WaveformColorStop(frame: $0.0, r: $0.1.0, g: $0.1.1, b: $0.1.2, a: $0.1.3) }
                .sorted { $0.frame < $1.frame }
        } else {
            colorStops = []
        }
        // A hullám színezése a cached képbe renderelődik, ezért újra kell renderelni.
        scheduleRender()
        needsDisplay = true
    }

    /// Beállítja (vagy törli) a kijelölt tartományt kívülről. Nem vált ki
    /// `onSelectionChanged` értesítést – csak a megjelenítést frissíti.
    func setSelection(_ range: (start: Int, end: Int)?) {
        if let r = range, r.end > r.start {
            selectionStart = min(r.start, r.end)
            selectionEnd   = max(r.start, r.end)
        } else {
            selectionStart = nil
            selectionEnd   = nil
        }
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
        // Kijelölés overlay (a markerek és kurzor alatt)
        drawSelection(ctx: ctx)
        // Lejátszási kurzor overlay
        drawCursor(ctx: ctx)
    }

    /// Kirajzolja a kijelölt tartományt áttetsző, a kurzortól/markerektől eltérő
    /// (kék) színnel, ha a látható ablakba esik.
    private func drawSelection(ctx: CGContext) {
        guard let s = selectionStart, let e = selectionEnd, e > s,
              storedSampleRate > 0, storedFrameCount > 0, bounds.width > 1 else { return }
        let totalDuration   = Double(storedFrameCount) / storedSampleRate
        let visibleDuration = totalDuration / max(1.0, currentZoom)
        guard visibleDuration > 0 else { return }

        let startRel = Double(s) / storedSampleRate - scrollOffsetSec
        let endRel   = Double(e) / storedSampleRate - scrollOffsetSec
        // Vágás a látható tartományra
        let clampedStart = max(0, min(visibleDuration, startRel))
        let clampedEnd   = max(0, min(visibleDuration, endRel))
        let x0 = CGFloat(clampedStart / visibleDuration) * bounds.width
        let x1 = CGFloat(clampedEnd   / visibleDuration) * bounds.width
        guard x1 > x0 else { return }

        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: bounds.height)
        ctx.setFillColor(CGColor(red: 0.30, green: 0.58, blue: 1.0, alpha: 0.28))
        ctx.fill(rect)
        ctx.setStrokeColor(CGColor(red: 0.40, green: 0.70, blue: 1.0, alpha: 0.90))
        ctx.setLineWidth(1.0)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
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
        let stops        = colorStops

        renderTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let image = Self.render(
                samples: samples,
                channelCount: channelCount,
                frameCount: frameCount,
                zoom: zoom,
                scrollOffset: scrollOffset,
                sampleRate: sampleRate,
                size: size,
                colorStops: stops
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

    // MARK: – Egér (kijelölés jobb gombbal)

    override func rightMouseDown(with event: NSEvent) {
        // A szülőpanel fókuszba hozása (a bal gombbal azonos módon)
        nextResponder?.mouseDown(with: event)
        let loc = convert(event.locationInWindow, from: nil)
        guard let frame = frameAt(x: loc.x) else { return }

        isSelecting    = true
        selectionAnchor = frame
        selectionStart = frame
        selectionEnd   = frame
        needsDisplay   = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isSelecting else {
            super.rightMouseDragged(with: event)
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        guard let frame = frameAt(x: loc.x) else { return }
        selectionStart = min(selectionAnchor, frame)
        selectionEnd   = max(selectionAnchor, frame)
        needsDisplay   = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isSelecting else {
            super.rightMouseUp(with: event)
            return
        }
        isSelecting = false
        let loc = convert(event.locationInWindow, from: nil)
        if let frame = frameAt(x: loc.x) {
            // Több rendszerben a secondary click clickCount nem megbízható, ezért
            // időalapú dupla-jobb-klikk felismerést is használunk.
            let interval = event.timestamp - lastRightClickTime
            let withinDoubleClickWindow = interval > 0 && interval <= NSEvent.doubleClickInterval
            let nearPreviousClick = {
                guard let prevX = lastRightClickX else { return false }
                return abs(prevX - loc.x) <= 12
            }()
            let isDoubleRightClick = event.clickCount >= 2 || (withinDoubleClickWindow && nearPreviousClick)
            if isDoubleRightClick, let range = markerBoundedSelection(around: frame) {
                selectionStart = range.start
                selectionEnd   = range.end
                onSelectionChanged?(range)
                needsDisplay = true
                lastRightClickTime = 0
                lastRightClickX = nil
                return
            }

            selectionStart = min(selectionAnchor, frame)
            selectionEnd   = max(selectionAnchor, frame)

            // Egy egyszerű jobb-klikket eltárolunk, hogy a következő kattintásnál
            // fallback módban felismerhető legyen a dupla-klikk.
            lastRightClickTime = event.timestamp
            lastRightClickX = loc.x
        }
        if let s = selectionStart, let e = selectionEnd, e > s {
            onSelectionChanged?((start: s, end: e))
        } else {
            // Üres tartomány (egyszerű kattintás) → kijelölés törlése
            selectionStart = nil
            selectionEnd   = nil
            onSelectionChanged?(nil)
        }
        needsDisplay = true
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

    /// Visszaadja a kattintási frame előtti legközelebbi és az utána következő
    /// marker közötti tartományt.
    ///
    /// Speciális eset: ha pontosan egy marker van, akkor
    /// - marker elé kattintva: [0, marker]
    /// - marker mögé kattintva: [marker, fájl vége]
    /// Egyébként, ha nincs mindkét oldalon marker, nil.
    private func markerBoundedSelection(around frame: Int) -> (start: Int, end: Int)? {
        if markerFrames.count == 1 {
            let marker = markerFrames[0]
            if frame < marker {
                let end = min(max(0, marker), storedFrameCount)
                return end > 0 ? (start: 0, end: end) : nil
            }
            if frame > marker {
                let start = min(max(0, marker), storedFrameCount)
                return storedFrameCount > start ? (start: start, end: storedFrameCount) : nil
            }
            return nil
        }

        guard markerFrames.count >= 2 else { return nil }
        let sorted = markerFrames.sorted()

        var left: Int?
        var right: Int?
        for marker in sorted {
            if marker < frame {
                left = marker
            } else if marker > frame {
                right = marker
                break
            }
        }

        guard let start = left, let end = right, end > start else { return nil }
        return (start: start, end: end)
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
        size:         CGSize,
        colorStops:   [WaveformColorStop]
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

        // Alapértelmezett hullámszín (RGB ≈ 64, 166, 255), 85% átlátszatlanság.
        let defR: CGFloat = 0.25, defG: CGFloat = 0.65, defB: CGFloat = 1.0, defA: CGFloat = 0.85
        // A színstopok frame szerint rendezettek; mivel a startFrame oszloponként
        // monoton nő, egy mutatóval végighaladhatunk rajtuk.
        var stopIdx = 0
        var curR = defR, curG = defG, curB = defB, curA = defA

        for col in 0..<w {
            if Task.isCancelled { return nil }

            let startFrame = min(max(0, frameCount - 1), scrollFrames + Int(Double(col) * framesPerPixel))
            let endFrame   = min(frameCount, max(startFrame + 1, scrollFrames + Int(Double(col + 1) * framesPerPixel)))

            // A szakaszhoz tartozó szín kiválasztása (utolsó stop, amelynek frame ≤ startFrame).
            while stopIdx < colorStops.count && colorStops[stopIdx].frame <= startFrame {
                curR = colorStops[stopIdx].r
                curG = colorStops[stopIdx].g
                curB = colorStops[stopIdx].b
                curA = colorStops[stopIdx].a
                stopIdx += 1
            }
            ctx.setFillColor(CGColor(red: curR, green: curG, blue: curB, alpha: curA))

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
