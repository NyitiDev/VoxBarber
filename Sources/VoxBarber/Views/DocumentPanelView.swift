import AppKit
import AVFoundation
import VoxBarberAudio

/// Egy hangdokumentum paneljenek nézete.
///
/// Mozgatható (de a szülő `WorkspaceView` határain belül marad),
/// átméretezhető (jobb alsó sarokból fogva), és tartalmaz:
///  - fejléc sávot (cím + bezáró gomb)
///  - eszköztárat (PLAY/PAUSE/STOP és COPY/CUT/PASTE csoportok)
///  - tartalom területet (hangforma megjelenítési helye)
@MainActor
final class DocumentPanelView: NSView {

    // MARK: – Layout konstansok

    private let titleBarH: CGFloat      = 30
    private let toolbarH: CGFloat       = 44
    private let rulerH: CGFloat         = 22
    private let resizeZoneSize: CGFloat = 18
    private let minWidth: CGFloat   = 320
    private let minHeight: CGFloat  = 200

    // A koordináta-rendszer: y=0 felül van (isFlipped = true)
    override var isFlipped: Bool { true }

    // MARK: – Fókusz követés

    /// Az éppen aktív (legutoljára kattintott) panel.
    /// Az AppDelegate `validateMenuItem` ezt használja a menüelemek engedélyezéséhez.
    static weak var focused: DocumentPanelView? {
        didSet { DocumentPanelView.refreshAll() }
    }

    /// Az éppen lejátszó panel – az élénk keret prioritása ezt követi.
    /// Ha van lejátszó panel, csak az lesz aktívnak vizualizálva.
    static weak var playing: DocumentPanelView? {
        didSet { DocumentPanelView.refreshAll() }
    }

    /// Minden regisztrált panel megjelenését frissíti.
    private static var allPanels: NSHashTable<DocumentPanelView> = .weakObjects()
    private static func refreshAll() {
        for panel in allPanels.allObjects { panel.updateAppearance() }
    }

    /// Igaz, ha a felhasználó kijelölt egy részt a hangformán.
    /// (A waveform modul implementálásakor állítja be; addig false.)
    var hasSelection: Bool = false

    /// A panel egyedi azonosítója – a lejátszás és a vágólap forráskövetéséhez.
    let panelID = UUID()

    /// A fejéc sáv nézetnek tárolt referenciája – megjelenés frissítéshez.
    private weak var titleBarView: NSView?

    /// A hanghullám megjelenítő nézet.
    private weak var waveformView: WaveformView?

    /// Az időskála nézet a waveform alatt.
    private weak var rulerView: TimeRulerView?

    /// A stopper label – a lejátszási pozíciót mutatja HH:MM:SS.mmmm formában.
    private weak var timeLabel: NSTextField?

    /// A stopper frissítésért felelős timer.
    private var playbackTimer: Timer?

    // MARK: – Hangadat

    /// A panel hangpuffere. Betöltéskor töltjük fel; üres puffer = új fájl.
    var audioBuffer: VoxBarberAudio.AudioBuffer = .empty()

    /// A kijelölés tartománya frame-ben (start, end). Nil = nincs kijelölés.
    var selectionRange: (start: Int, end: Int)? {
        didSet { hasSelection = selectionRange != nil }
    }

    /// A lejátszási / beillesztési kurzor pozíciója frame-ben.
    var cursorFrame: Int = 0

    /// Aktuális zoom szint (1.0 = teljes fájl látszik, >1.0 = nagyítva).
    /// A waveform nézet ezt használja majd a megjelenítési tartomány számításához.
    var zoomLevel: Double = 1.0

    /// Maximális zoom szint.
    private let zoomMax: Double = 64.0

    /// A megnyitott fájl URL-je (mentéshez).
    private(set) var fileURL: URL?

    // MARK: – Callback

    /// A bezáró gomb megnyomásakor hívódik meg.
    var onClose: (() -> Void)?

    // MARK: – Drag/resize állapot

    private var isDragging  = false
    private var isResizing  = false
    /// Az egér pozíciója az akció kezdetén (szülő koordinátarendszerben)
    private var dragStartMouseInParent: NSPoint = .zero
    /// A panel frame-je az akció kezdetén
    private var dragStartFrame: NSRect = .zero

    // MARK: – Inicializálás

    /// - Parameters:
    ///   - frame: A panel kezdeti kerete a szülő koordinátarendszerében.
    ///   - title: A fejléc sávon megjelenő szöveg (pl. fájlnév).
    ///   - fileURL: Az opcionális fájl URL; nil = üres / új fájl.
    init(frame: NSRect, title: String, fileURL: URL?) {
        self.fileURL = fileURL
        super.init(frame: frame)
        buildView(title: title)
        DocumentPanelView.allPanels.add(self)
        // Ha van fájl URL, betöltjük háttérben
        if let url = fileURL {
            loadAudio(from: url)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView(title: "Ismeretlen")
        DocumentPanelView.allPanels.add(self)
    }

    // MARK: – Nézet felépítése

    private func buildView(title: String) {
        wantsLayer = true

        // Panel alap kinézet
        layer?.backgroundColor = NSColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1.0).cgColor
        layer?.cornerRadius    = 8
        layer?.borderWidth     = 1
        layer?.borderColor     = NSColor(white: 0.32, alpha: 1.0).cgColor
        layer?.shadowOpacity   = 0.45
        layer?.shadowRadius    = 10
        layer?.shadowOffset    = CGSize(width: 0, height: -3)

        buildTitleBar(title: title)
        buildToolbar()
        buildContentArea()
    }

    // MARK: – Fejléc sáv

    private func buildTitleBar(title: String) {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(red: 0.21, green: 0.21, blue: 0.24, alpha: 1.0).cgColor
        bar.layer?.cornerRadius = 8
        bar.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.titleBarView = bar
        addSubview(bar)

        // Cím label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font        = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor   = NSColor(white: 0.88, alpha: 1.0)
        titleLabel.alignment   = .center
        titleLabel.drawsBackground = false
        bar.addSubview(titleLabel)

        // Bezáró gomb (✕)
        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle   = .inline
        closeBtn.isBordered   = false
        closeBtn.font         = NSFont.systemFont(ofSize: 11)
        closeBtn.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
        bar.addSubview(closeBtn)

        // Stopper label (jobb felső sarok)
        let tLabel = NSTextField(labelWithString: "00:00:00.0000")
        tLabel.translatesAutoresizingMaskIntoConstraints = false
        tLabel.font            = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        tLabel.textColor       = NSColor(white: 0.65, alpha: 1.0)
        tLabel.alignment       = .right
        tLabel.drawsBackground = false
        bar.addSubview(tLabel)
        self.timeLabel = tLabel

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: titleBarH),

            titleLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 36),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tLabel.leadingAnchor, constant: -4),

            tLabel.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -6),
            tLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            closeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 22),
            closeBtn.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    // MARK: – Eszköztár

    private func buildToolbar() {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0).cgColor
        addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: titleBarH),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH)
        ])

        // Bal csoport: lejátszás vezérlők
        let playBtn  = makeToolbarButton(symbol: "play.fill",  tooltip: "Lejátszás",  action: #selector(playTapped))
        let pauseBtn = makeToolbarButton(symbol: "pause.fill", tooltip: "Szünet",     action: #selector(pauseTapped))
        let stopBtn  = makeToolbarButton(symbol: "stop.fill",  tooltip: "Leállítás",  action: #selector(stopTapped))

        // Középső csoport: szerkesztés vezérlők
        let copyBtn  = makeToolbarButton(symbol: "doc.on.doc",        tooltip: "Másol",     action: #selector(copyTapped))
        let cutBtn   = makeToolbarButton(symbol: "scissors",          tooltip: "Kivág",     action: #selector(cutTapped))
        let pasteBtn = makeToolbarButton(symbol: "doc.on.clipboard",  tooltip: "Beilleszt", action: #selector(pasteTapped))

        // Jobb csoport: zoom + scroll vezérlők
        let zoomInBtn    = makeToolbarButton(symbol: "plus.magnifyingglass",  tooltip: "Zoom be",   action: #selector(zoomInTapped))
        let zoomOutBtn   = makeToolbarButton(symbol: "minus.magnifyingglass", tooltip: "Zoom ki",   action: #selector(zoomOutTapped))
        let scrollLeftBtn  = makeToolbarButton(symbol: "chevron.left",  tooltip: "Görgetés balra",  action: #selector(scrollLeftTapped))
        let scrollRightBtn = makeToolbarButton(symbol: "chevron.right", tooltip: "Görgetés jobbra", action: #selector(scrollRightTapped))

        // Negyedik csoport: info
        let infoBtn = makeToolbarButton(symbol: "info.circle", tooltip: "Fájlinformáció", action: #selector(infoTapped))

        // Elválasztó vonal az első és második csoport között
        let sep1 = NSView()
        sep1.translatesAutoresizingMaskIntoConstraints = false
        sep1.wantsLayer = true
        sep1.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor

        // Elválasztó vonal a második és harmadik csoport között
        let sep2 = NSView()
        sep2.translatesAutoresizingMaskIntoConstraints = false
        sep2.wantsLayer = true
        sep2.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor

        // Elválasztó vonal a harmadik és negyedik csoport között
        let sep3 = NSView()
        sep3.translatesAutoresizingMaskIntoConstraints = false
        sep3.wantsLayer = true
        sep3.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor

        for v in [playBtn, pauseBtn, stopBtn, sep1, copyBtn, cutBtn, pasteBtn, sep2, zoomInBtn, zoomOutBtn, scrollLeftBtn, scrollRightBtn, sep3, infoBtn] {
            toolbar.addSubview(v)
        }

        NSLayoutConstraint.activate([
            // PLAY csoport – bal szél
            playBtn.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            playBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pauseBtn.leadingAnchor.constraint(equalTo: playBtn.trailingAnchor, constant: 4),
            pauseBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            stopBtn.leadingAnchor.constraint(equalTo: pauseBtn.trailingAnchor, constant: 4),
            stopBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // Elválasztó 1
            sep1.leadingAnchor.constraint(equalTo: stopBtn.trailingAnchor, constant: 12),
            sep1.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sep1.widthAnchor.constraint(equalToConstant: 1),
            sep1.heightAnchor.constraint(equalToConstant: 22),

            // COPY csoport
            copyBtn.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 12),
            copyBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            cutBtn.leadingAnchor.constraint(equalTo: copyBtn.trailingAnchor, constant: 4),
            cutBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pasteBtn.leadingAnchor.constraint(equalTo: cutBtn.trailingAnchor, constant: 4),
            pasteBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // Elválasztó 2
            sep2.leadingAnchor.constraint(equalTo: pasteBtn.trailingAnchor, constant: 12),
            sep2.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sep2.widthAnchor.constraint(equalToConstant: 1),
            sep2.heightAnchor.constraint(equalToConstant: 22),

            // ZOOM csoport
            zoomInBtn.leadingAnchor.constraint(equalTo: sep2.trailingAnchor, constant: 12),
            zoomInBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            zoomOutBtn.leadingAnchor.constraint(equalTo: zoomInBtn.trailingAnchor, constant: 4),
            zoomOutBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollLeftBtn.leadingAnchor.constraint(equalTo: zoomOutBtn.trailingAnchor, constant: 4),
            scrollLeftBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollRightBtn.leadingAnchor.constraint(equalTo: scrollLeftBtn.trailingAnchor, constant: 4),
            scrollRightBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // Elválasztó 3
            sep3.leadingAnchor.constraint(equalTo: scrollRightBtn.trailingAnchor, constant: 12),
            sep3.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sep3.widthAnchor.constraint(equalToConstant: 1),
            sep3.heightAnchor.constraint(equalToConstant: 22),

            // INFO csoport
            infoBtn.leadingAnchor.constraint(equalTo: sep3.trailingAnchor, constant: 12),
            infoBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
    }

    /// SF Symbol alapú toolbar gombot hoz létre.
    private func makeToolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .rounded
        btn.toolTip    = tooltip
        btn.imagePosition = .imageOnly

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            btn.image = img
        } else {
            // SF Symbol fallback: rövid szöveges felirat
            btn.title = String(tooltip.prefix(4))
            btn.font  = NSFont.systemFont(ofSize: 10)
        }

        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 32),
            btn.heightAnchor.constraint(equalToConstant: 28)
        ])
        return btn
    }

    // MARK: – Tartalom terület

    private func buildContentArea() {
        let wv = WaveformView()
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.wantsLayer = true
        addSubview(wv)
        self.waveformView = wv

        let rv = TimeRulerView()
        rv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rv)
        self.rulerView = rv

        // Scroll szinkronizálás: WaveformView drag → TimeRulerView frissítés
        wv.onScrollOffsetChanged = { [weak rv] offset in
            rv?.setScrollOffset(offset)
        }

        // Átméretező fogantyú (jobb alsó sarok)
        let handle = ResizeHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor, constant: titleBarH + toolbarH),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -rulerH),

            rv.topAnchor.constraint(equalTo: wv.bottomAnchor),
            rv.leadingAnchor.constraint(equalTo: leadingAnchor),
            rv.trailingAnchor.constraint(equalTo: trailingAnchor),
            rv.bottomAnchor.constraint(equalTo: bottomAnchor),
            rv.heightAnchor.constraint(equalToConstant: rulerH),

            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: resizeZoneSize),
            handle.heightAnchor.constraint(equalToConstant: resizeZoneSize)
        ])
    }

    // MARK: – Segédfüggvény

    /// A panel előterébe helyezi (z-sorrendben).
    func bringToFront() {
        guard let parent = superview else { return }
        parent.addSubview(self) // re-add → z-order tetejére kerül
    }

    /// Frissíti a panel keretének és fejécének színét az aktív állapot alapján.
    /// Logika: ha van lejátszó panel, csak az kap színt; ha nincs, a fókuszált.
    private func updateAppearance() {
        let active: Bool
        if let p = DocumentPanelView.playing {
            active = p === self
        } else {
            active = DocumentPanelView.focused === self
        }
        let borderColor: CGColor = active
            ? NSColor.controlAccentColor.cgColor
            : NSColor(white: 0.32, alpha: 1.0).cgColor
        let titleBg: CGColor = active
            ? NSColor(red: 0.15, green: 0.26, blue: 0.44, alpha: 1.0).cgColor
            : NSColor(red: 0.21, green: 0.21, blue: 0.24, alpha: 1.0).cgColor
        layer?.borderColor = borderColor
        layer?.borderWidth = active ? 1.5 : 1.0
        titleBarView?.layer?.backgroundColor = titleBg
    }

    // MARK: – Egér esemény kezelés (mozgatás + átméretezés)

    override func mouseDown(with event: NSEvent) {
        // Bármelyik panelre kattintva ez lesz az aktív panel (menüvalidáció alapja)
        DocumentPanelView.focused = self

        let loc = convert(event.locationInWindow, from: nil)

        // Átméretezési zóna: jobb alsó sarok (flipped koordinátákban y:height = alul)
        let isInResizeZone = loc.x >= bounds.width  - resizeZoneSize
                          && loc.y >= bounds.height - resizeZoneSize

        // Cím sáv: felső sáv (flipped koordinátákban y:0 = felül)
        let isInTitleBar = loc.y <= titleBarH

        if isInResizeZone {
            isResizing = true
            isDragging = false
        } else if isInTitleBar {
            isDragging = true
            isResizing = false
        } else {
            super.mouseDown(with: event)
            return
        }

        // Kezdeti állapot rögzítése szülő koordinátarendszerben
        dragStartMouseInParent = (superview ?? self).convert(event.locationInWindow, from: nil)
        dragStartFrame = frame

        // Panel előtérbe hozása
        bringToFront()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging || isResizing else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouse = (superview ?? self).convert(event.locationInWindow, from: nil)
        let dx = currentMouse.x - dragStartMouseInParent.x
        let dy = currentMouse.y - dragStartMouseInParent.y

        if isDragging {
            // Mozgatás: az origin eltolása az egér delta-jával
            var newFrame = NSRect(
                x: dragStartFrame.origin.x + dx,
                y: dragStartFrame.origin.y + dy,
                width: dragStartFrame.width,
                height: dragStartFrame.height
            )
            // Korlátozás a szülő munkaterületen belülre
            if let ws = superview as? WorkspaceView {
                newFrame = ws.constrainPanel(self, to: newFrame)
            }
            frame = newFrame

        } else if isResizing {
            // Átméretezés: szélesség jobbra, magasság lefelé nő (flipped koordinátákban)
            let newW = max(minWidth,  dragStartFrame.width  + dx)
            let newH = max(minHeight, dragStartFrame.height + dy)

            var newFrame = NSRect(
                x: dragStartFrame.origin.x,
                y: dragStartFrame.origin.y,
                width: newW,
                height: newH
            )
            if let ws = superview as? WorkspaceView {
                newFrame = ws.constrainPanel(self, to: newFrame)
                // Ha a jobb/alsó szél eléri a munkaterület határát, a méretet is korlátozzuk
                newFrame.size.width  = min(newW,  ws.bounds.width  - newFrame.origin.x)
                newFrame.size.height = min(newH,  ws.bounds.height - newFrame.origin.y)
            }
            frame = newFrame
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        isResizing = false
    }

    // MARK: – Stopper

    /// Elindítja a stopper frissítő timert (~30 fps).
    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickTimer() }
        }
    }

    /// Megállítja a stopper timert.
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Frissíti a stopper labelt az aktuális lejátszási pozíció alapján.
    private func tickTimer() {
        let frame = AudioEngine.shared.currentPlaybackFrame()
        timeLabel?.stringValue = formatPlaybackTime(frame: frame)
        waveformView?.setCursorFrame(frame)
    }

    /// Frame-számot alakít HH:MM:SS.mmmm formátummá.
    /// Az `mmmm` 0,1 ms pontosságú (4 digit = 10^-4 s).
    private func formatPlaybackTime(frame: Int) -> String {
        let sr = audioBuffer.sampleRate > 0 ? audioBuffer.sampleRate : 44100
        let totalSec = Double(max(0, frame)) / sr
        let h    = Int(totalSec) / 3600
        let m    = (Int(totalSec) % 3600) / 60
        let s    = Int(totalSec) % 60
        let frac: Int
        let fracSec = totalSec - Double(Int(totalSec))
        frac = Int(fracSec * 10000)
        return String(format: "%02d:%02d:%02d.%04d", h, m, s, frac)
    }

    // MARK: – Gomb akciók

    @objc private func closeTapped() {
        stopPlaybackTimer()
        // 1. Ha ez a panel játszik, állítsuk le
        if AudioEngine.shared.currentPlayingPanelID == panelID {
            if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
            AudioEngine.shared.stop()
        }

        // 2. Ha a vágólapon erről a panelről van adat, kérdezzünk rá
        if AudioClipboard.shared.sourcePanelID == panelID {
            let alert = NSAlert()
            alert.messageText = "Vágólap megtartása?"
            alert.informativeText = "A vágólapon levő hangrészlet ebből a fájlból származik. Megtartod, hogy egy másik fájlba be tudd illeszteni?"
            alert.addButton(withTitle: "Megtart")
            alert.addButton(withTitle: "Eldobja")
            if alert.runModal() == .alertSecondButtonReturn {
                AudioClipboard.shared.clear()
            }
        }

        onClose?()
    }

    // MARK: – Lejátszás akciók

    @objc private func playTapped() {
        DocumentPanelView.playing = self
        AudioEngine.shared.play(audioBuffer, fromFrame: cursorFrame, panelID: panelID)
        startPlaybackTimer()
    }

    @objc private func pauseTapped() {
        stopPlaybackTimer()
        cursorFrame = AudioEngine.shared.currentPlaybackFrame()
        timeLabel?.stringValue = formatPlaybackTime(frame: cursorFrame)
        waveformView?.setCursorFrame(cursorFrame)
        if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
        AudioEngine.shared.pause()
    }

    @objc private func stopTapped() {
        stopPlaybackTimer()
        if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
        AudioEngine.shared.stop()
        cursorFrame = 0
        timeLabel?.stringValue = "00:00:00.0000"
        waveformView?.setCursorFrame(-1)
    }

    // MARK: – Szerkesztés akciók

    @objc func copyTapped() {
        guard let range = selectionRange else { return }
        let clip = audioBuffer.slice(from: range.start, to: range.end)
        AudioClipboard.shared.store(clip, sourcePanelID: panelID)
    }

    @objc func cutTapped() {
        guard let range = selectionRange else { return }
        let clip = audioBuffer.slice(from: range.start, to: range.end)
        AudioClipboard.shared.store(clip, sourcePanelID: panelID)
        audioBuffer = audioBuffer.deleting(from: range.start, to: range.end)
        cursorFrame = range.start
        selectionRange = nil
        // TODO: waveform újrarajzolás
    }

    @objc func pasteTapped() {
        guard let clip = AudioClipboard.shared.peek() else { return }
        audioBuffer = audioBuffer.inserting(clip, at: cursorFrame)
        cursorFrame += clip.frameCount
        selectionRange = nil
        // TODO: waveform újrarajzolás
    }

    // MARK: – Zoom akciók

    @objc func zoomInTapped() {
        zoomLevel = min(zoomMax, zoomLevel * 2.0)
        waveformView?.setZoom(zoomLevel)
        rulerView?.setZoom(zoomLevel)
    }

    @objc func zoomOutTapped() {
        zoomLevel = max(1.0, zoomLevel / 2.0)
        waveformView?.setZoom(zoomLevel)
        rulerView?.setZoom(zoomLevel)
    }

    @objc func scrollLeftTapped() {
        guard zoomLevel > 1.0, audioBuffer.frameCount > 0 else { return }
        let totalDuration   = Double(audioBuffer.frameCount) / audioBuffer.sampleRate
        let visibleDuration = totalDuration / zoomLevel
        let step            = visibleDuration / 4.0
        let newOffset       = max(0.0, (waveformView?.currentScrollOffset ?? 0) - step)
        waveformView?.setScrollOffset(newOffset)
        rulerView?.setScrollOffset(newOffset)
    }

    @objc func scrollRightTapped() {
        guard zoomLevel > 1.0, audioBuffer.frameCount > 0 else { return }
        let totalDuration   = Double(audioBuffer.frameCount) / audioBuffer.sampleRate
        let visibleDuration = totalDuration / zoomLevel
        let maxOffset       = max(0.0, totalDuration - visibleDuration)
        let step            = visibleDuration / 4.0
        let newOffset       = min(maxOffset, (waveformView?.currentScrollOffset ?? 0) + step)
        waveformView?.setScrollOffset(newOffset)
        rulerView?.setScrollOffset(newOffset)
    }

    // MARK: – Info akció

    @objc func infoTapped() {
        let url = fileURL
        let buffer = audioBuffer

        // Alap fájladatok
        var lines: [String] = []

        if let url = url {
            lines.append("Név:  \(url.lastPathComponent)")
            lines.append("Elérési út:  \(url.path)")
            lines.append("Típus:  \(url.pathExtension.uppercased())")
        } else {
            lines.append("Név:  (mentetlen új fájl)")
        }

        let sr = buffer.sampleRate > 0 ? buffer.sampleRate : 44100
        let totalSec = Double(buffer.frameCount) / sr
        let h = Int(totalSec) / 3600
        let m = (Int(totalSec) % 3600) / 60
        let s = Int(totalSec) % 60
        let fracSec = totalSec - Double(Int(totalSec))
        let ms = Int(fracSec * 1000)
        lines.append("Hossz:  \(String(format: "%02d:%02d:%02d.%03d", h, m, s, ms))")
        lines.append("Csatornák:  \(buffer.channelCount)")
        lines.append("Mintavételi frekvencia:  \(Int(sr)) Hz")

        // Metaadat olvasás AVAsset-tel (aszinkron, main thread-en)
        guard let url = url else {
            showInfoPanel(lines: lines)
            return
        }

        Task {
            let asset = AVURLAsset(url: url)
            var metaLines: [String] = []

            // AVFoundation közös metaadat kulcsok
            let metaItems = try? await asset.load(.commonMetadata)
            for item in metaItems ?? [] {
                guard let key = item.commonKey else { continue }
                let value = (try? await item.load(.stringValue)) ?? ""
                switch key {
                case .commonKeyTitle:       metaLines.append("Cím:  \(value)")
                case .commonKeyArtist:      metaLines.append("Előadó:  \(value)")
                case .commonKeyAlbumName:   metaLines.append("Album:  \(value)")
                case .commonKeyCreationDate: metaLines.append("Kiadás éve:  \(value)")
                case .commonKeyType:        metaLines.append("Műfaj:  \(value)")
                default: break
                }
            }

            await MainActor.run {
                self.showInfoPanel(lines: lines + (metaLines.isEmpty ? [] : [""] + metaLines))
            }
        }
    }

    /// Megjeleníti a fájlinformációs panelt.
    private func showInfoPanel(lines: [String]) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .closable, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Fájlinformáció"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 6
        stack.edgeInsets  = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let label: NSTextField
            if parts.count == 2 {
                let attr = NSMutableAttributedString()
                let keyAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
                let valAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                attr.append(NSAttributedString(string: parts[0] + ": ", attributes: keyAttrs))
                attr.append(NSAttributedString(string: parts[1].trimmingCharacters(in: .whitespaces), attributes: valAttrs))
                label = NSTextField(labelWithAttributedString: attr)
            } else {
                label = NSTextField(labelWithString: line)
                label.font = NSFont.systemFont(ofSize: 12)
            }
            label.isSelectable = true
            stack.addArrangedSubview(label)
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
        panel.setContentSize(stack.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: – Hangfájl betöltés

    /// Aszinkron betölti a hangfájlt az `AudioEngine` segítségével.
    func loadAudio(from url: URL) {
        self.fileURL = url
        Task {
            do {
                let buffer = try AudioEngine.shared.load(url: url)
                await MainActor.run {
                    self.audioBuffer = buffer
                    self.waveformView?.setBuffer(buffer, zoom: self.zoomLevel)
                    self.rulerView?.configure(
                        sampleRate: buffer.sampleRate,
                        frameCount: buffer.frameCount,
                        zoom: self.zoomLevel
                    )
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Betöltési hiba"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: – Átméretező fogantyú nézet

/// A jobb alsó sarokban megjelenő vizuális átméretező jelző.
/// Három párhuzamos átlós vonallal jelzi az átméretezhetőséget.
private final class ResizeHandleView: NSView {

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(white: 0.42, alpha: 1.0)
        color.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round

        // Három átlós vonal (jobb alsó sarokból kiindulva, flipped koordinátákban)
        let offsets: [CGFloat] = [4, 8, 12]
        for offset in offsets {
            let x1 = bounds.width - offset
            let y1 = bounds.height - 2
            let x2 = bounds.width - 2
            let y2 = bounds.height - offset
            path.move(to: NSPoint(x: x1, y: y1))
            path.line(to: NSPoint(x: x2, y: y2))
        }
        path.stroke()
    }
}
