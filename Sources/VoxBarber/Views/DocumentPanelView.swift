import AppKit
import AVFoundation
import VoxBarberAudio
import UniformTypeIdentifiers
import os

/// Egy hangdokumentum paneljenek nézete.
///
/// Mozgatható (de a szülő `WorkspaceView` határain belül marad),
/// átméretezhető (jobb alsó sarokból fogva), és tartalmaz:
///  - fejléc sávot (cím + bezáró gomb)
///  - eszköztárat (PLAY/PAUSE/STOP és COPY/CUT/PASTE csoportok)
///  - tartalom területet (hangforma megjelenítési helye)
@MainActor
final class DocumentPanelView: NSView, NSTextFieldDelegate, NSWindowDelegate {

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

    /// A "követés" toggle gomb – lenyomva tartja a kurzort a látható ablakban.
    private weak var followBtn: NSButton?

    /// A toolbar SF Symbol gombjai – a téma "gombok színe" alkalmazásához.
    private var toolbarButtons: [NSButton] = []

    /// Szerkesztés toolbar gombok állapotkezeléshez.
    private weak var copyButton: NSButton?
    private weak var cutButton: NSButton?
    private weak var pasteButton: NSButton?
    private weak var mixButton: NSButton?

    /// A stopper label – a lejátszási pozíciót mutatja HH:MM:SS.mmmm formában.
    private weak var timeLabel: NSTextField?

    /// A stopper frissítésért felelős timer.
    private var playbackTimer: Timer?

    /// Ha nem nil, a lejátszás ennél a frame-nél automatikusan megáll
    /// (kijelölt rész lejátszásához). A megálláskor nullázódik.
    private var playbackStopFrame: Int?

    // MARK: – Hangadat

    /// A panel hangpuffere. Betöltéskor töltjük fel; üres puffer = új fájl.
    var audioBuffer: VoxBarberAudio.AudioBuffer = .empty()

    /// A kijelölés tartománya frame-ben (start, end). Nil = nincs kijelölés.
    var selectionRange: (start: Int, end: Int)? {
        didSet {
            hasSelection = selectionRange != nil
            waveformView?.setSelection(selectionRange)
            updateEditingButtonsState()
        }
    }

    /// A lejátszási / beillesztési kurzor pozíciója frame-ben.
    var cursorFrame: Int = 0
    /// Ennek a panelnek a hangerő-szintje (0.0 – 1.0). Alapértelmezett: 50%.
    private var volumeLevel: Float = 0.5
    /// Lejátszás-követés: ha igaz, a scroll automatikusan lapoz, ha a kurzor
    /// elhagyja a látható ablak jobb szélét.
    private var followPlayback: Bool = false

    /// Aktuális zoom szint (1.0 = teljes fájl látszik, >1.0 = nagyítva).
    /// A waveform nézet ezt használja majd a megjelenítési tartomány számításához.
    var zoomLevel: Double = 1.0

    /// Maximális zoom szint.
    private let zoomMax: Double = 64.0

    /// A megnyitott fájl URL-je (mentéshez).
    private(set) var fileURL: URL?

    /// Egy jelölőpont színe RGBA komponensekkel (perzisztálható, NSColor-független).
    struct MarkerColor: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        /// NSColor-ból építi fel (sRGB komponensekkel).
        init(_ ns: NSColor) {
            let c = ns.usingColorSpace(.sRGB) ?? ns
            self.r = Double(c.redComponent)
            self.g = Double(c.greenComponent)
            self.b = Double(c.blueComponent)
            self.a = Double(c.alphaComponent)
        }

        /// Alapértelmezett hullámszín: RGB ≈ 64, 166, 255, 85% átlátszatlanság.
        static let `default` = MarkerColor(r: 0.25, g: 0.65, b: 1.0, a: 0.85)

        /// AppKit színné alakítja (sRGB).
        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }
    }

    /// Egy jelölőpont a hangformán: egyedi azonosító, név, frame-pozíció és szín.
    /// A szín azt jelenti, hogy ettől a ponttól kezdve a hullámot ezzel rajzoljuk.
    struct AudioMarker: Identifiable {
        let id = UUID()
        var name: String
        var frame: Int
        var color: MarkerColor = .default
    }

    /// A panel jelölőpontjai. Időrendben (frame szerint) tartjuk rendezve.
    private var markers: [AudioMarker] = []

    /// A jelölőpontok listáját megjelenítő ablak (egyszerre csak egy).
    private weak var markersWindow: NSWindow?

    /// Az "időpontra ugrás" párbeszédablak (egyszerre csak egy).
    /// Erős referencia: különben az ablak megsemmisülne, mielőtt megjelenne.
    private var jumpTimeWindow: NSWindow?

    /// Az "időpontra ugrás" ablak szövegmezője.
    private weak var jumpTimeField: NSTextField?

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
        startObservingClipboardChanges()
        startObservingThemeChanges()
        DocumentPanelView.allPanels.add(self)
        // Ha van fájl URL, betöltjük háttérben
        if let url = fileURL {
            loadAudio(from: url)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView(title: "Ismeretlen")
        startObservingClipboardChanges()
        startObservingThemeChanges()
        DocumentPanelView.allPanels.add(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

        // Bezáró gomb – piros kör, bal felső sarok (macOS traffic light stílus)
        let closeBtn = NSButton(title: "", target: self, action: #selector(closeTapped))
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle   = .regularSquare
        closeBtn.isBordered   = false
        closeBtn.imagePosition = .imageOnly        // ne legyen szövegkeret
        closeBtn.wantsLayer   = true
        closeBtn.layer?.cornerRadius = 6
        closeBtn.layer?.masksToBounds = true
        closeBtn.layer?.backgroundColor = NSColor.systemRed.cgColor
        closeBtn.toolTip = "Bezárás"
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
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeBtn.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tLabel.leadingAnchor, constant: -4),

            tLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            tLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            closeBtn.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            closeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 12),
            closeBtn.heightAnchor.constraint(equalToConstant: 12)
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
        let jumpBtn  = makeToolbarButton(symbol: "forward.end.fill", tooltip: "Ugrás a következő jelölőpontra", action: #selector(jumpToNextMarkerTapped))
        let jumpToEndBtn = makeToolbarButton(symbol: "chevron.right.2", tooltip: "Ugrás a fájl végére", action: #selector(jumpToEndTapped))
        let jumpTimeBtn = makeToolbarButton(symbol: "clock.arrow.circlepath", tooltip: "Ugrás időpontra", action: #selector(jumpToTimeTapped))

        // Hangerő ikon + csúzka
        let volIcon = NSImageView()
        volIcon.translatesAutoresizingMaskIntoConstraints = false
        volIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "Hangerő")
        volIcon.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            volIcon.widthAnchor.constraint(equalToConstant: 16),
            volIcon.heightAnchor.constraint(equalToConstant: 16)
        ])

        let volSlider = NSSlider(value: Double(volumeLevel), minValue: 0, maxValue: 1,
                                 target: self, action: #selector(volumeChanged(_:)))
        volSlider.translatesAutoresizingMaskIntoConstraints = false
        volSlider.sliderType     = .linear
        volSlider.isContinuous   = true
        volSlider.toolTip        = "Hangerő"
        NSLayoutConstraint.activate([
            volSlider.widthAnchor.constraint(equalToConstant: 72),
            volSlider.heightAnchor.constraint(equalToConstant: 20)
        ])

        // Középső csoport: szerkesztés vezérlők
        let markerBtn = makeToolbarButton(symbol: "mappin.and.ellipse", tooltip: "Új jelölőpont", action: #selector(addMarkerTapped))
        let copyBtn  = makeToolbarButton(symbol: "doc.on.doc",        tooltip: "Másol",     action: #selector(copyTapped))
        let cutBtn   = makeToolbarButton(symbol: "scissors",          tooltip: "Kivág",     action: #selector(cutTapped))
        let pasteBtn = makeToolbarButton(symbol: "doc.on.clipboard",  tooltip: "Beilleszt", action: #selector(pasteTapped))
        let mixBtn   = makeToolbarButton(symbol: "square.stack.3d.up", tooltip: "Összemosás", action: #selector(mixTapped))
        self.copyButton = copyBtn
        self.cutButton = cutBtn
        self.pasteButton = pasteBtn
        self.mixButton = mixBtn

        // Jobb csoport: zoom + scroll vezérlők
        let followToggle = NSButton(title: "", target: self, action: #selector(followTapped))
        followToggle.translatesAutoresizingMaskIntoConstraints = false
        followToggle.bezelStyle    = .regularSquare
        followToggle.isBordered    = false
        followToggle.setButtonType(.toggle)
        followToggle.toolTip       = "Követés"
        followToggle.imagePosition = .imageOnly
        followToggle.wantsLayer    = true
        followToggle.layer?.cornerRadius = 6
        followToggle.layer?.backgroundColor = NSColor.clear.cgColor
        if let img = NSImage(systemSymbolName: "arrow.forward.to.line", accessibilityDescription: "Követés") {
            followToggle.image = img
        } else {
            followToggle.title = "KÖV"
            followToggle.font  = NSFont.systemFont(ofSize: 9)
        }
        followToggle.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            followToggle.widthAnchor.constraint(equalToConstant: 32),
            followToggle.heightAnchor.constraint(equalToConstant: 28)
        ])
        self.followBtn = followToggle

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

        for v in [playBtn, pauseBtn, stopBtn, jumpBtn, jumpToEndBtn, jumpTimeBtn, volIcon, volSlider, sep1, markerBtn, copyBtn, cutBtn, pasteBtn, mixBtn, sep2, followToggle, zoomInBtn, zoomOutBtn, scrollLeftBtn, scrollRightBtn, sep3, infoBtn] {
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

            jumpBtn.leadingAnchor.constraint(equalTo: stopBtn.trailingAnchor, constant: 4),
            jumpBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            jumpToEndBtn.leadingAnchor.constraint(equalTo: jumpBtn.trailingAnchor, constant: 4),
            jumpToEndBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            jumpTimeBtn.leadingAnchor.constraint(equalTo: jumpToEndBtn.trailingAnchor, constant: 4),
            jumpTimeBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            volIcon.leadingAnchor.constraint(equalTo: jumpTimeBtn.trailingAnchor, constant: 8),
            volIcon.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            volSlider.leadingAnchor.constraint(equalTo: volIcon.trailingAnchor, constant: 4),
            volSlider.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // Elválasztó 1
            sep1.leadingAnchor.constraint(equalTo: volSlider.trailingAnchor, constant: 8),
            sep1.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sep1.widthAnchor.constraint(equalToConstant: 1),
            sep1.heightAnchor.constraint(equalToConstant: 22),

            // COPY csoport
            markerBtn.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 12),
            markerBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            copyBtn.leadingAnchor.constraint(equalTo: markerBtn.trailingAnchor, constant: 4),
            copyBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            cutBtn.leadingAnchor.constraint(equalTo: copyBtn.trailingAnchor, constant: 4),
            cutBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            pasteBtn.leadingAnchor.constraint(equalTo: cutBtn.trailingAnchor, constant: 4),
            pasteBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            mixBtn.leadingAnchor.constraint(equalTo: pasteBtn.trailingAnchor, constant: 4),
            mixBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // Elválasztó 2
            sep2.leadingAnchor.constraint(equalTo: mixBtn.trailingAnchor, constant: 12),
            sep2.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            sep2.widthAnchor.constraint(equalToConstant: 1),
            sep2.heightAnchor.constraint(equalToConstant: 22),

            // ZOOM csoport
            followToggle.leadingAnchor.constraint(equalTo: sep2.trailingAnchor, constant: 12),
            followToggle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            zoomInBtn.leadingAnchor.constraint(equalTo: followToggle.trailingAnchor, constant: 4),
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

        updateEditingButtonsState()
    }

    /// A szerkesztés gombok állapotát szinkronban tartja a kijelöléssel és a vágólappal.
    private func updateEditingButtonsState() {
        let hasSelection = selectionRange != nil
        copyButton?.isEnabled = hasSelection
        cutButton?.isEnabled = hasSelection
        pasteButton?.isEnabled = AudioClipboard.shared.hasContent
        mixButton?.isEnabled = AudioClipboard.shared.hasContent
    }

    private func startObservingClipboardChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardDidChange),
            name: .audioClipboardDidChange,
            object: nil
        )
    }

    @objc private func clipboardDidChange() {
        updateEditingButtonsState()
    }

    private func startObservingThemeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeColorsChanged),
            name: ThemeManager.changedNotification,
            object: nil
        )
    }

    /// A téma színeinek megváltozásakor újraszínezzük a toolbar gombokat.
    @objc private func themeColorsChanged() {
        applyButtonTint()
    }

    /// A toolbar gombok ikonszínét a téma "gombok színe" értékére állítja.
    private func applyButtonTint() {
        let tint = ThemeManager.shared.colors.button.nsColor
        for btn in toolbarButtons {
            btn.contentTintColor = tint
        }
    }

    /// SF Symbol alapú toolbar gombot hoz létre.
    private func makeToolbarButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .rounded
        btn.toolTip    = tooltip
        btn.imagePosition = .imageOnly
        btn.contentTintColor = ThemeManager.shared.colors.button.nsColor

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
        toolbarButtons.append(btn)
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

        // Kattintás a hangformára → kurzor / lejátszás ugratás
        wv.onSeek = { [weak self] frame in
            self?.seek(toFrame: frame)
        }

        // Jobb egérgombos húzás a hangformán → kijelölés
        wv.onSelectionChanged = { [weak self] range in
            self?.selectionRange = range
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

    /// Frissíti a stopper labelt az aktuális lejátszási pozíció alapján,
    /// és ha a követés aktív, lapoz, ha a kurzor elhagyja a látható ablakot.
    private func tickTimer() {
        let frame = AudioEngine.shared.currentPlaybackFrame()

        // Kijelölt rész lejátszása: ha elértük a tartomány végét, megállunk ott.
        if let stop = playbackStopFrame, frame >= stop {
            stopPlaybackTimer()
            if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
            AudioEngine.shared.stop()
            playbackStopFrame = nil
            cursorFrame = stop
            timeLabel?.stringValue = formatPlaybackTime(frame: stop)
            waveformView?.setCursorFrame(stop)
            return
        }

        // A lejátszás elérte (vagy túllépte) a hangfájl végét: leállítjuk a stoppert
        // és a lejátszást, különben a timer a fájl vége után is tovább pörögne.
        if audioBuffer.frameCount > 0, frame >= audioBuffer.frameCount {
            handlePlaybackReachedEnd()
            return
        }

        cursorFrame = frame
        timeLabel?.stringValue = formatPlaybackTime(frame: frame)
        waveformView?.setCursorFrame(frame)

        // Követés: ha a kurzor a látható ablak jobb széle mögé ért, lapozzunk
        if followPlayback,
           audioBuffer.frameCount > 0,
           audioBuffer.sampleRate > 0,
           zoomLevel > 1.0 {
            let totalDuration   = Double(audioBuffer.frameCount) / audioBuffer.sampleRate
            let visibleDuration = totalDuration / zoomLevel
            let cursorSec       = Double(frame) / audioBuffer.sampleRate
            let currentOffset   = waveformView?.currentScrollOffset ?? 0
            let windowEnd       = currentOffset + visibleDuration

            if cursorSec >= windowEnd {
                // Lapozzunk egy teljes ablaknyit előre
                let maxOffset  = max(0.0, totalDuration - visibleDuration)
                let newOffset  = min(maxOffset, currentOffset + visibleDuration)
                waveformView?.setScrollOffset(newOffset)
                rulerView?.setScrollOffset(newOffset)
            }
        }
    }

    /// A lejátszás a fájl végére ért: megállítja a stoppert és a lejátszást,
    /// a kurzort a fájl végére állítja.
    private func handlePlaybackReachedEnd() {
        stopPlaybackTimer()
        if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
        AudioEngine.shared.stop()
        cursorFrame = audioBuffer.frameCount
        timeLabel?.stringValue = formatPlaybackTime(frame: cursorFrame)
        waveformView?.setCursorFrame(cursorFrame)
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

    /// Igaz, ha éppen szól ennek a panelnek a hangja.
    private var isPlaying: Bool { playbackTimer != nil }

    /// A hangformára kattintás hatása: a kurzort a megadott frame-re állítja.
    /// Ha éppen szól a hangfájl, a lejátszás is odaugrik; ha nem, csak a kurzor
    /// mozdul, és a következő play/pause innen indul.
    private func seek(toFrame frame: Int) {
        let clamped = max(0, min(audioBuffer.frameCount, frame))
        cursorFrame = clamped
        timeLabel?.stringValue = formatPlaybackTime(frame: clamped)
        waveformView?.setCursorFrame(clamped)

        if isPlaying {
            // Lejátszás közben: ugrik a lejátszás az új pozícióra
            AudioEngine.shared.setVolume(volumeLevel)
            AudioEngine.shared.play(audioBuffer, fromFrame: clamped, panelID: panelID)
        }
    }

    @objc private func playTapped() {
        DocumentPanelView.playing = self
        playbackStopFrame = nil
        AudioEngine.shared.setVolume(volumeLevel)
        AudioEngine.shared.play(audioBuffer, fromFrame: cursorFrame, panelID: panelID)
        startPlaybackTimer()
    }

    // MARK: – Lejátszás menü belépési pontok

    /// Lejátszás a hangfájl elejétől (Lejátszás menü).
    func playFromStartMenu() {
        cursorFrame = 0
        timeLabel?.stringValue = formatPlaybackTime(frame: 0)
        waveformView?.setCursorFrame(0)
        DocumentPanelView.playing = self
        playbackStopFrame = nil
        AudioEngine.shared.setVolume(volumeLevel)
        AudioEngine.shared.play(audioBuffer, fromFrame: 0, panelID: panelID)
        startPlaybackTimer()
    }

    /// Lejátszás a kijelölt ponttól, azaz a kurzor jelenlegi helyétől (Lejátszás menü).
    func playFromCursorMenu() {
        playTapped()
    }

    /// A kijelölt rész lejátszása: a kijelölés elejétől a végéig (Lejátszás menü).
    func playSelectionMenu() {
        guard let range = selectionRange else { return }
        let start = max(0, min(audioBuffer.frameCount, range.start))
        let end   = max(start, min(audioBuffer.frameCount, range.end))
        cursorFrame = start
        timeLabel?.stringValue = formatPlaybackTime(frame: start)
        waveformView?.setCursorFrame(start)
        DocumentPanelView.playing = self
        playbackStopFrame = end
        AudioEngine.shared.setVolume(volumeLevel)
        AudioEngine.shared.play(audioBuffer, fromFrame: start, panelID: panelID)
        startPlaybackTimer()
    }

    @objc private func pauseTapped() {
        stopPlaybackTimer()
        playbackStopFrame = nil
        cursorFrame = AudioEngine.shared.currentPlaybackFrame()
        timeLabel?.stringValue = formatPlaybackTime(frame: cursorFrame)
        waveformView?.setCursorFrame(cursorFrame)
        if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
        AudioEngine.shared.pause()
    }

    @objc private func stopTapped() {
        stopPlaybackTimer()
        playbackStopFrame = nil
        if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
        AudioEngine.shared.stop()
        cursorFrame = 0
        timeLabel?.stringValue = "00:00:00.0000"
        waveformView?.setCursorFrame(-1)
    }

    /// Ugrás a következő jelölőpontra: a kurzort (és lejátszás közben a
    /// lejátszást is) a jelenlegi pozíciónál későbbi első markerre állítja.
    /// Ha nincs további marker, körbe-ugrik az első (legkorábbi) markerre.
    @objc private func jumpToNextMarkerTapped() {
        let sortedFrames = markers.map(\.frame).sorted()
        guard !sortedFrames.isEmpty else { return }
        let current = isPlaying ? AudioEngine.shared.currentPlaybackFrame() : cursorFrame
        let target = sortedFrames.first(where: { $0 > current }) ?? sortedFrames[0]
        seek(toFrame: target)
    }

    /// Ugrás a fájl végére: a kurzort (és lejátszás közben a lejátszást is)
    /// a hangállomány utolsó frame pozíciójára állítja.
    @objc private func jumpToEndTapped() {
        seek(toFrame: audioBuffer.frameCount)
    }

    /// Időpontra ugrás: megnyit egy kis ablakot, ahol óra.perc.másodperc.ezredmp
    /// formában meg lehet adni a célpozíciót. A gomb megnyomásakor – ha szólt a
    /// zene – a lejátszás leáll.
    @objc private func jumpToTimeTapped() {
        // Ha szól a zene, állítsuk le.
        if isPlaying {
            stopPlaybackTimer()
            cursorFrame = AudioEngine.shared.currentPlaybackFrame()
            timeLabel?.stringValue = formatPlaybackTime(frame: cursorFrame)
            waveformView?.setCursorFrame(cursorFrame)
            if DocumentPanelView.playing === self { DocumentPanelView.playing = nil }
            AudioEngine.shared.pause()
        }

        // Ha már nyitva van, frissítsük a mezőt és hozzuk előtérbe.
        if let panel = jumpTimeWindow {
            jumpTimeField?.stringValue = formatPlaybackTime(frame: cursorFrame)
            panel.makeKeyAndOrderFront(nil)
            if let field = jumpTimeField { panel.makeFirstResponder(field) }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Ugrás időpontra"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        jumpTimeWindow = panel

        let field = NSTextField(string: formatPlaybackTime(frame: cursorFrame))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "ó.p.mp.ezred"
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.target = self
        field.action = #selector(jumpTimeConfirmed)
        jumpTimeField = field

        let okBtn = NSButton(title: "OKÉ", target: self, action: #selector(jumpTimeConfirmed))
        okBtn.translatesAutoresizingMaskIntoConstraints = false
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"

        let stack = NSStackView(views: [field, okBtn])
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 10
        stack.edgeInsets  = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])

        panel.contentView = container
        panel.setContentSize(stack.fittingSize)
        panel.initialFirstResponder = field
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Az OKÉ gomb / Enter hatása: feldolgozza a beírt időpontot, odaugrik, és
    /// bezárja a párbeszédablakot.
    @objc private func jumpTimeConfirmed() {
        guard let text = jumpTimeField?.stringValue else { return }
        if let seconds = Self.parseJumpTime(text) {
            let sr = audioBuffer.sampleRate > 0 ? audioBuffer.sampleRate : 44100
            let frame = Int((seconds * sr).rounded())
            seek(toFrame: frame)
            jumpTimeWindow?.close()
            jumpTimeWindow = nil
        } else {
            NSSound.beep()
        }
    }

    /// Az ablak bezárásakor (a piros gombbal is) nullázzuk a referenciát.
    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win === jumpTimeWindow {
            jumpTimeWindow = nil
        }
        // A jelölőpontok listája bezárásakor minden onnan nyitott al-ablakot is
        // bezárunk (a színválasztó panelt, amit a sor-színkutak nyitnak meg).
        if let win = notification.object as? NSWindow, win === markersWindow {
            let colorPanel = NSColorPanel.shared
            if colorPanel.isVisible {
                colorPanel.orderOut(nil)
            }
            markersWindow = nil
        }
    }

    /// Feldolgozza az `óra.perc.másodperc.ezredmásodperc` formátumú időpontot
    /// másodpercre. Az elválasztó lehet pont vagy kettőspont, kivéve az utolsót
    /// (az ezredmásodperc előtt), amely csak pont lehet.
    /// - Returns: A másodpercben kifejezett időpont, vagy nil érvénytelen bemenetnél.
    static func parseJumpTime(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Az utolsó elválasztó (az ezredmásodperc előtt) csak pont lehet.
        guard let lastDot = trimmed.lastIndex(of: ".") else { return nil }
        // Az ezredmásodperc rész nem tartalmazhat további elválasztót.
        let afterLast = trimmed[trimmed.index(after: lastDot)...]
        guard !afterLast.contains(":"), !afterLast.contains(".") else { return nil }

        let head = String(trimmed[..<lastDot])
        let millisPart = String(afterLast)
        guard !millisPart.isEmpty else { return nil }

        // A fej részben pont és kettőspont is lehet elválasztó.
        let headComponents = head.split(whereSeparator: { $0 == "." || $0 == ":" }).map(String.init)
        guard headComponents.count >= 1, headComponents.count <= 3 else { return nil }

        // Minden komponens csak számjegy lehet.
        func intValue(_ s: String) -> Int? {
            guard !s.isEmpty, s.allSatisfy(\.isNumber) else { return nil }
            return Int(s)
        }

        // A fej: [óra, perc, másodperc] – a komponensek száma szerint.
        var hours = 0, minutes = 0, secs = 0
        switch headComponents.count {
        case 1:
            guard let s = intValue(headComponents[0]) else { return nil }
            secs = s
        case 2:
            guard let m = intValue(headComponents[0]),
                  let s = intValue(headComponents[1]) else { return nil }
            minutes = m; secs = s
        default: // 3
            guard let h = intValue(headComponents[0]),
                  let m = intValue(headComponents[1]),
                  let s = intValue(headComponents[2]) else { return nil }
            hours = h; minutes = m; secs = s
        }

        // Ezredmásodperc: legfeljebb 4 számjegy (0.0001 mp felbontás).
        guard millisPart.allSatisfy(\.isNumber), millisPart.count <= 4 else { return nil }
        let fraction = Double("0." + millisPart) ?? 0

        return Double(hours) * 3600 + Double(minutes) * 60 + Double(secs) + fraction
    }

    /// A toolbar MARKER+ gombja: új jelölőpontot tesz a kurzorpozícióra.
    @objc private func addMarkerTapped() {
        addMarkerAtCursor()
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
        cursorFrame = max(0, min(audioBuffer.frameCount, range.start))
        selectionRange = nil
        waveformView?.setBuffer(audioBuffer, zoom: zoomLevel)
        rulerView?.configure(sampleRate: audioBuffer.sampleRate,
                             frameCount: audioBuffer.frameCount,
                             zoom: zoomLevel)
        waveformView?.setCursorFrame(cursorFrame)
        refreshMarkerOverlay()
    }

    @objc func pasteTapped() {
        guard let clip = AudioClipboard.shared.peek() else { return }
        let insertionFrame = max(0, min(audioBuffer.frameCount, cursorFrame))
        let wasEmptyBuffer = audioBuffer.frameCount == 0

        audioBuffer = audioBuffer.inserting(clip, at: insertionFrame)
        // Üres dokumentumba illesztéskor a lejátszás azonnal induljon Play-re,
        // ezért a kurzort a frissen beillesztett rész elején tartjuk.
        cursorFrame = wasEmptyBuffer ? insertionFrame : insertionFrame + clip.frameCount
        selectionRange = nil

        // A beillesztési pont utáni hangtartalom clip.frameCount frame-mel eltolódik,
        // ezért a meglévő, ezen a ponton vagy utána lévő jelölőpontokat is eltoljuk,
        // hogy a hanganyaghoz képest ugyanott maradjanak, mint a beillesztés előtt.
        for i in markers.indices where markers[i].frame >= insertionFrame {
            markers[i].frame += clip.frameCount
        }

        // A beillesztett rész elejét és végét automatikusan megjelöljük.
        let pasteStart = insertionFrame
        let pasteEnd   = insertionFrame + clip.frameCount
        addMarker(atFrame: pasteStart, name: "Beillesztés eleje")
        addMarker(atFrame: pasteEnd,   name: "Beillesztés vége")

        waveformView?.setBuffer(audioBuffer, zoom: zoomLevel)
        rulerView?.configure(sampleRate: audioBuffer.sampleRate,
                             frameCount: audioBuffer.frameCount,
                             zoom: zoomLevel)
        waveformView?.setCursorFrame(cursorFrame)
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// A vágólapon lévő hangrészletet a kurzorpozíciótól összemossa (mixeli) a
    /// jelenlegi hanganyaggal – nem közbeékelődik, hanem a két jel összeadódik.
    @objc func mixTapped() {
        guard let clip = AudioClipboard.shared.peek() else { return }

        // A két hangrészlet egymáshoz viszonyított hangerejének bekérése.
        guard let gains = askMixGains() else { return }

        let mixFrame = max(0, min(audioBuffer.frameCount, cursorFrame))
        let wasEmptyBuffer = audioBuffer.frameCount == 0

        audioBuffer = audioBuffer.mixing(clip, at: mixFrame,
                                         existingGain: gains.existing,
                                         incomingGain: gains.incoming)
        // A mixelés megnövelheti a puffert, ha a beékelt anyag túlnyúlna a fájl
        // végén; ekkor a túllógó részben már csak a beillesztett hang szól.
        let mixEnd = min(audioBuffer.frameCount, mixFrame + clip.frameCount)
        // Üres dokumentumba mixeléskor a kurzort a frissen beillesztett rész
        // elején tartjuk, egyébként a mixelt rész végére visszük.
        cursorFrame = wasEmptyBuffer ? mixFrame : mixEnd
        selectionRange = nil

        // A mixelt rész elejét és végét automatikusan megjelöljük. A mixelés nem
        // tolja el a meglévő hanganyagot, így a többi jelölőpont a helyén marad.
        addMarker(atFrame: mixFrame, name: "Összemosás eleje")
        addMarker(atFrame: mixEnd, name: "Összemosás vége")

        waveformView?.setBuffer(audioBuffer, zoom: zoomLevel)
        rulerView?.configure(sampleRate: audioBuffer.sampleRate,
                             frameCount: audioBuffer.frameCount,
                             zoom: zoomLevel)
        waveformView?.setCursorFrame(cursorFrame)
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// Bekéri a felhasználótól a két hangrészlet egymáshoz viszonyított hangerejét
    /// összemosáskor. Egyetlen csúszka szabályozza az arányt: a csúszka eleje a
    /// célfájl, a vége a beillesztendő hang. A csúszka felett bal és jobb oldalon
    /// a két százalékos arány látható, melyek összege mindig 100%.
    /// Nil = a felhasználó megszakította.
    private func askMixGains() -> (existing: Float, incoming: Float)? {
        let alert = NSAlert()
        alert.messageText = "Összemosás aránya"
        alert.informativeText = "Állítsd be a két hangrészlet egymáshoz viszonyított hangerejét."

        let width: CGFloat = 320
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 56))

        // Bal oldali (célfájl) és jobb oldali (beillesztett) százalék-címkék.
        let existingLabel = NSTextField(labelWithString: "Célfájl: 50%")
        existingLabel.frame = NSRect(x: 0, y: 32, width: width / 2, height: 20)
        existingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        existingLabel.alignment = .left

        let incomingLabel = NSTextField(labelWithString: "Beillesztendő: 50%")
        incomingLabel.frame = NSRect(x: width / 2, y: 32, width: width / 2, height: 20)
        incomingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        incomingLabel.alignment = .right

        // A csúszka értéke = a célfájl hang aránya (0–100%). 50% = kiegyenlített.
        // A csúszka elején (0%) a célfájl néma, a beillesztendő 100%-on szól.
        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.frame = NSRect(x: 0, y: 4, width: width, height: 22)

        accessory.addSubview(existingLabel)
        accessory.addSubview(incomingLabel)
        accessory.addSubview(slider)

        // A %-címkék élő frissítése a csúszka mozgatásakor.
        let updater = MixRatioSliderUpdater(slider: slider,
                                            existingLabel: existingLabel,
                                            incomingLabel: incomingLabel)
        slider.target = updater
        slider.action = #selector(MixRatioSliderUpdater.sliderChanged(_:))

        alert.accessoryView = accessory
        alert.addButton(withTitle: "Összemos")
        alert.addButton(withTitle: "Mégse")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let existingRatio = Float(slider.doubleValue / 100.0)
        return (existing: existingRatio, incoming: 1.0 - existingRatio)
    }

    // MARK: – Jelölőpont akciók

    /// Igaz, ha a panelnek van legalább egy jelölőpontja.
    var hasMarkers: Bool { !markers.isEmpty }

    /// Új jelölőpontot hoz létre az aktuális kurzorpozíción.
    /// A jelölőpontokat időrendben tartjuk, és a hangformán feltűnő vonallal jelöljük.
    func addMarkerAtCursor() {
        // Lejátszás közben a friss lejátszási pozíciót használjuk.
        let sourceFrame = isPlaying ? AudioEngine.shared.currentPlaybackFrame() : cursorFrame
        let frame = max(0, min(audioBuffer.frameCount, sourceFrame))
        let name  = "Jelölő \(markers.count + 1)"
        markers.append(AudioMarker(name: name, frame: frame))
        markers.sort { $0.frame < $1.frame }
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// Ha van kijelölt tartomány, jelölőpontot helyez el a kijelölés elejére és
    /// a végére is.
    func markSelectionEnds() {
        guard let range = selectionRange else { return }
        let start = min(range.start, range.end)
        let end   = max(range.start, range.end)
        addMarker(atFrame: start, name: "Kijelölés eleje")
        addMarker(atFrame: end,   name: "Kijelölés vége")
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// Jelölőpontot helyez el egy adott frame-pozícióra a megadott névvel.
    /// Ha az adott frame-en már van jelölőpont, nem hoz létre duplikátumot.
    /// A hívó felelős a hangform/lista frissítéséért.
    private func addMarker(atFrame rawFrame: Int, name: String) {
        let frame = max(0, min(audioBuffer.frameCount, rawFrame))
        guard !markers.contains(where: { $0.frame == frame }) else { return }
        markers.append(AudioMarker(name: name, frame: frame))
        markers.sort { $0.frame < $1.frame }
    }

    /// Frissíti a hangformán megjelenő jelölővonalakat.
    private func refreshMarkerOverlay() {
        waveformView?.setMarkerFrames(
            markers.map(\.frame),
            names: markers.map(\.name),
            colors: markers.map {
                (CGFloat($0.color.r), CGFloat($0.color.g), CGFloat($0.color.b), CGFloat($0.color.a))
            }
        )
    }

    /// Megnyitja (vagy előtérbe hozza) a jelölőpontok listáját tartalmazó ablakot.
    func showMarkersList() {
        if let win = markersWindow {
            win.makeKeyAndOrderFront(nil)
            rebuildMarkersWindowContent()
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        win.title = "Jelölőpontok"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self
        markersWindow = win
        rebuildMarkersWindowContent()
        win.center()
        win.makeKeyAndOrderFront(nil)
    }

    /// Újraépíti a jelölőpont-ablak tartalmát az aktuális `markers` lista alapján.
    private func rebuildMarkersWindowContent() {
        guard let win = markersWindow else { return }

        let root = NSView()

        // Felső terület: lista vagy üres állapot.
        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        if markers.isEmpty {
            let empty = NSTextField(labelWithString: "Nincs még jelölőpont.")
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.textColor = .secondaryLabelColor
            listContainer.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor)
            ])
        } else {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment   = .leading
            stack.spacing     = 6
            stack.edgeInsets  = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            stack.translatesAutoresizingMaskIntoConstraints = false

            for marker in markers {
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing     = 8
                row.translatesAutoresizingMaskIntoConstraints = false

                // Idő címke
                let timeLabel = NSTextField(labelWithString: formatPlaybackTime(frame: marker.frame))
                timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                timeLabel.textColor = .secondaryLabelColor
                timeLabel.setContentHuggingPriority(.required, for: .horizontal)

                // Szerkeszthető névmező
                let nameField = NSTextField(string: marker.name)
                nameField.translatesAutoresizingMaskIntoConstraints = false
                nameField.font = NSFont.systemFont(ofSize: 12)
                nameField.delegate = self
                nameField.target = self
                nameField.action = #selector(markerNameChanged(_:))
                nameField.identifier = NSUserInterfaceItemIdentifier(marker.id.uuidString)
                nameField.widthAnchor.constraint(equalToConstant: 250).isActive = true

                // Színválasztó: ettől a ponttól kezdve ezzel a színnel rajzoljuk a hullámot.
                let colorWell = NSColorWell()
                colorWell.translatesAutoresizingMaskIntoConstraints = false
                colorWell.color = marker.color.nsColor
                colorWell.target = self
                colorWell.action = #selector(markerColorChanged(_:))
                colorWell.identifier = NSUserInterfaceItemIdentifier(marker.id.uuidString)
                colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
                colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
                colorWell.setContentHuggingPriority(.required, for: .horizontal)

                // Törlés gomb
                let delBtn = NSButton(title: "", target: self, action: #selector(deleteMarkerTapped(_:)))
                delBtn.bezelStyle = .inline
                delBtn.isBordered = false
                delBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Törlés")
                delBtn.contentTintColor = .systemRed
                delBtn.identifier = NSUserInterfaceItemIdentifier(marker.id.uuidString)
                delBtn.setContentHuggingPriority(.required, for: .horizontal)
                delBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

                row.addArrangedSubview(timeLabel)
                row.addArrangedSubview(nameField)
                row.addArrangedSubview(colorWell)
                row.addArrangedSubview(delBtn)
                stack.addArrangedSubview(row)
            }

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let doc = NSView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(stack)
            scroll.documentView = doc

            listContainer.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: listContainer.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

                stack.topAnchor.constraint(equalTo: doc.topAnchor),
                stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.widthAnchor)
            ])
        }

        // Alsó gombsor: Mentés / Betöltés / Bezár.
        let saveBtn = NSButton(title: "Mentés…", target: self, action: #selector(saveMarkersTapped))
        saveBtn.bezelStyle = .rounded
        saveBtn.isEnabled = !markers.isEmpty
        let loadBtn = NSButton(title: "Betöltés…", target: self, action: #selector(loadMarkersTapped))
        loadBtn.bezelStyle = .rounded
        let closeBtn = NSButton(title: "Bezár", target: self, action: #selector(closeMarkersWindowTapped))
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"   // Esc

        let buttonBar = NSStackView(views: [loadBtn, saveBtn, NSView(), closeBtn])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 8
        buttonBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(listContainer)
        root.addSubview(buttonBar)
        NSLayoutConstraint.activate([
            listContainer.topAnchor.constraint(equalTo: root.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            buttonBar.topAnchor.constraint(equalTo: listContainer.bottomAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        win.contentView = root
    }

    /// A jelölőpont nevének szerkesztésekor hívódik (Enter / fókuszvesztés).
    @objc private func markerNameChanged(_ sender: NSTextField) {
        updateMarkerName(from: sender)
    }

    /// Minden beütésnél hívódik – így a hangformán élőben frissül a név.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        updateMarkerName(from: field)
    }

    /// A megadott mező azonosítója alapján frissíti a marker nevét és a hangformát.
    private func updateMarkerName(from field: NSTextField) {
        guard let idString = field.identifier?.rawValue,
              let idx = markers.firstIndex(where: { $0.id.uuidString == idString }) else { return }
        markers[idx].name = field.stringValue
        refreshMarkerOverlay()
    }

    /// Egy jelölőpont törlése a lista törlés gombjáról.
    @objc private func deleteMarkerTapped(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue else { return }
        markers.removeAll { $0.id.uuidString == idString }
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// A színválasztó megváltozásakor frissíti a jelölőpont színét és a hullámot.
    @objc private func markerColorChanged(_ sender: NSColorWell) {
        guard let idString = sender.identifier?.rawValue,
              let idx = markers.firstIndex(where: { $0.id.uuidString == idString }) else { return }
        markers[idx].color = MarkerColor(sender.color)
        refreshMarkerOverlay()
    }

    /// A "Bezár" gomb: bezárja a jelölőpontok listáját tartalmazó ablakot.
    @objc private func closeMarkersWindowTapped() {
        markersWindow?.close()
    }

    // MARK: – Jelölőpont lista mentés / betöltés (VBM)

    /// A VBM (VoxBarber Maker) fájl szerializálható formátuma.
    private struct MarkerFile: Codable {
        var version: Int = 1
        var audioFileName: String?
        var audioFilePath: String?
        var sampleRate: Double
        var markers: [Item]
        struct Item: Codable {
            var name: String
            var frame: Int
            var color: MarkerColor?
        }
    }

    /// A VBM fájlok típusa (egyedi kiterjesztés alapján).
    private static let vbmType: UTType = UTType(filenameExtension: "vbm") ?? .data

    /// Mentés gomb: VBM fájlba menti a jelölőpontokat.
    @objc private func saveMarkersTapped() {
        guard !markers.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.vbmType]
        panel.canCreateDirectories = true
        // Alapértelmezett fájlnév a hangfájl nevéből.
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? "Jelölőpontok"
        panel.nameFieldStringValue = "\(baseName).vbm"

        let win = markersWindow
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.writeMarkers(to: url)
        }
        if let win {
            panel.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    /// Betöltés gomb: VBM fájlból olvassa vissza a jelölőpontokat.
    @objc private func loadMarkersTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [Self.vbmType]

        let win = markersWindow
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.readMarkers(from: url)
        }
        if let win {
            panel.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    /// Publikus belépési pont a menüből: ugyanaz, mint a betöltés gomb.
    func loadMarkersFromMenu() {
        loadMarkersTapped()
    }

    /// A jelölőpontokat a megadott URL-re írja JSON formátumban.
    private func writeMarkers(to url: URL) {
        let file = MarkerFile(
            audioFileName: fileURL?.lastPathComponent,
            audioFilePath: fileURL?.path,
            sampleRate: audioBuffer.sampleRate,
            markers: markers.map { MarkerFile.Item(name: $0.name, frame: $0.frame, color: $0.color) }
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            presentMarkerError("A jelölőpontok mentése nem sikerült.", error)
        }
    }

    /// A megadott URL-ről olvassa be és állítja vissza a jelölőpontokat.
    /// Ha már vannak markerek, megkérdezi az egyesítés módját.
    private func readMarkers(from url: URL) {
        let loaded: [AudioMarker]
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(MarkerFile.self, from: data)
            loaded = file.markers.map { AudioMarker(name: $0.name, frame: $0.frame, color: $0.color ?? .default) }
        } catch {
            presentMarkerError("A jelölőpontok betöltése nem sikerült.", error)
            return
        }

        // Ha nincs még marker, egyszerűen betöltjük.
        guard !markers.isEmpty else {
            applyLoadedMarkers(loaded, mode: .replace)
            return
        }

        // Egyesítési mód bekérése a felhasználótól.
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Jelölőpontok betöltése"
        alert.informativeText = "Már vannak jelölőpontok. Hogyan történjen a betöltés?"
        alert.addButton(withTitle: "Újratöltés")    // törli a meglévőket
        alert.addButton(withTitle: "Visszatöltés")  // egyezésnél a betöltött név nyer
        alert.addButton(withTitle: "Összemosás")    // egyezésnél a meglévő név marad
        alert.addButton(withTitle: "Mégse")

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:  self.applyLoadedMarkers(loaded, mode: .replace)
            case .alertSecondButtonReturn: self.applyLoadedMarkers(loaded, mode: .reload)
            case .alertThirdButtonReturn:  self.applyLoadedMarkers(loaded, mode: .merge)
            default: break  // Mégse
            }
        }

        if let win = markersWindow {
            alert.beginSheetModal(for: win, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// A jelölőpont-betöltés egyesítési módjai.
    private enum MarkerMergeMode {
        case replace  // Újratöltés: a meglévők törlődnek, csak a betöltöttek maradnak
        case reload   // Visszatöltés: egyezésnél a betöltött név írja felül a meglévőt
        case merge    // Összemosás: egyezésnél a meglévő név marad meg
    }

    /// Alkalmazza a betöltött markereket a megadott mód szerint.
    private func applyLoadedMarkers(_ loaded: [AudioMarker], mode: MarkerMergeMode) {
        switch mode {
        case .replace:
            markers = loaded

        case .reload, .merge:
            let loadedFrames = Set(loaded.map(\.frame))
            // A meglévők közül megtartjuk azokat, amelyek időpontja nincs a betöltöttek között.
            let keptExisting = markers.filter { !loadedFrames.contains($0.frame) }

            if mode == .reload {
                // Egyezésnél a betöltött név nyer → a betöltöttek a mérvadók.
                markers = keptExisting + loaded
            } else {
                // Összemosás: egyezésnél a meglévő név marad meg.
                let existingFrames = Set(markers.map(\.frame))
                let newOnes = loaded.filter { !existingFrames.contains($0.frame) }
                markers = markers + newOnes
            }
        }
        markers.sort { $0.frame < $1.frame }
        refreshMarkerOverlay()
        rebuildMarkersWindowContent()
    }

    /// Hibaüzenetet jelenít meg a felhasználónak.
    private func presentMarkerError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let win = markersWindow {
            alert.beginSheetModal(for: win, completionHandler: nil)
        } else {
            alert.runModal()
        }
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

    @objc private func volumeChanged(_ sender: NSSlider) {
        volumeLevel = Float(sender.doubleValue)
        // Ha éppen ez a panel szól, azonnal alkalmazzuk
        if DocumentPanelView.playing === self {
            AudioEngine.shared.setVolume(volumeLevel)
        }
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

    @objc func followTapped() {
        followPlayback = followBtn?.state == .on
        followBtn?.contentTintColor = followPlayback ? .controlAccentColor : .secondaryLabelColor
        let bg: CGColor = followPlayback
            ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
        followBtn?.layer?.backgroundColor = bg
    }

    /// A lejátszás-követés jelenlegi állapota (a menü pipa megjelenítéséhez).
    var isFollowingPlayback: Bool { followPlayback }

    /// Átkapcsolja a lejátszás-követést – a gyerek-ablak "követés" gombjával
    /// azonos viselkedés. A toolbar gomb állapotát is szinkronizálja.
    func toggleFollowPlayback() {
        followBtn?.state = followPlayback ? .off : .on
        followTapped()
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
            var bitrateLine: String?
            let log = Logger(subsystem: "VoxBarber", category: "Metadata")

            // Forrásfájl bitrátája az audiosáv becsült adatsebességéből.
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                if let track = tracks.first {
                    let dataRate = try await track.load(.estimatedDataRate)
                    if dataRate > 0 {
                        let kbps = Int((dataRate / 1000).rounded())
                        bitrateLine = "Bitráta:  \(kbps) kbps"
                    }
                }
            } catch {
                log.error("Bitráta betöltése sikertelen: \(error.localizedDescription, privacy: .public)")
            }

            // AVFoundation közös metaadat kulcsok
            let metaItems: [AVMetadataItem]
            do {
                metaItems = try await asset.load(.commonMetadata)
            } catch {
                log.error("Metaadat betöltése sikertelen: \(error.localizedDescription, privacy: .public)")
                metaItems = []
            }
            for item in metaItems {
                guard let key = item.commonKey else { continue }
                let value: String
                do {
                    value = try await item.load(.stringValue) ?? ""
                } catch {
                    log.error("Metaadat érték betöltése sikertelen (\(key.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    continue
                }
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
                var infoLines = lines
                if let bitrateLine = bitrateLine {
                    infoLines.append(bitrateLine)
                }
                self.showInfoPanel(lines: infoLines + (metaLines.isEmpty ? [] : [""] + metaLines))
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
    /// A dekódolás háttér-szálon fut (`Task.detached`), így soha nem fagyasztja a
    /// felhasználói felületet; a puffer beállítása a fő szálon történik.
    func loadAudio(from url: URL) {
        self.fileURL = url
        Task.detached {
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

// MARK: – Összemosás arány-csúszka frissítő

/// A „Összemosás aránya” párbeszéd egyetlen csúszkájának élő %-kijelzéséért felel.
/// A csúszka értéke a célfájl hang aránya; a beillesztendő aránya az ehhez tartozó
/// kiegészítő érték (a kettő összege mindig 100%).
@MainActor
private final class MixRatioSliderUpdater: NSObject {
    private let slider: NSSlider
    private let existingLabel: NSTextField
    private let incomingLabel: NSTextField

    init(slider: NSSlider, existingLabel: NSTextField, incomingLabel: NSTextField) {
        self.slider = slider
        self.existingLabel = existingLabel
        self.incomingLabel = incomingLabel
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let existing = Int(sender.doubleValue.rounded())
        let incoming = 100 - existing
        existingLabel.stringValue = "Célfájl: \(existing)%"
        incomingLabel.stringValue = "Beillesztendő: \(incoming)%"
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
