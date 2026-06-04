import AppKit

/// A főablak munkaterülete.
///
/// Ez a nézet tartalmazza az összes `DocumentPanelView`-t.
/// Gondoskodik arról, hogy a panelek ne legyenek kihúzhatók a határain kívülre,
/// és az ablak átméretezésekor visszarendezi a kiszakadt paneleket.
@MainActor
final class WorkspaceView: NSView {

    // A koordináta-rendszer: y=0 felül van (isFlipped = true)
    override var isFlipped: Bool { true }

    // MARK: – Privát állapot

    private var panels: [DocumentPanelView] = []

    // MARK: – Inicializálás

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        // Sötét munkaterület háttér
        layer?.backgroundColor = NSColor(
            red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0
        ).cgColor
    }

    // MARK: – Panel hozzáadás

    /// Új dokumentum panelt ad hozzuk a munkaterülethez.
    /// - Parameters:
    ///   - title: A panel fejlécén megjelenő fájlnév vagy cím.
    ///   - fileURL: Az opcionális fájl URL (megnyitott fájl esetén); nil ha üres panel.
    func addPanel(title: String, fileURL: URL?) {
        let panel = makePanel(title: title, fileURL: fileURL)
        addSubview(panel)
        panels.append(panel)
        // Az újonnan nyíló panel kerüljön előtérbe
        panel.bringToFront()
    }

    // MARK: – Panel létrehozás

    private func makePanel(title: String, fileURL: URL?) -> DocumentPanelView {
        // Panelszélesség: a munkaterület ~90%-a (plan: „legszélesebb")
        let workWidth  = bounds.width  > 0 ? bounds.width  : 1000

        let panelWidth  = max(400, workWidth * 0.90)
        let panelHeight = CGFloat(280)

        // Lépcsőzetes elhelyezés, hogy ne fedjék teljesen egymást
        let cascade = CGFloat(panels.count) * 24
        let x = max(0, (workWidth - panelWidth) / 2 + cascade)
        let y = max(0, 24 + cascade)

        let frame = constrainRect(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            panelSize: NSSize(width: panelWidth, height: panelHeight)
        )

        let panel = DocumentPanelView(frame: frame, title: title, fileURL: fileURL)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.removePanel(panel)
        }
        return panel
    }

    private func removePanel(_ panel: DocumentPanelView) {
        panel.removeFromSuperview()
        panels.removeAll { $0 === panel }
    }

    // MARK: – Ablak elrendezések

    /// A paneleket egyenlő szélességű vízszintes sávokba rendezi.
    func arrangeHorizontal() {
        guard !panels.isEmpty else { return }
        let w = bounds.width  > 0 ? bounds.width  : 1000
        let h = bounds.height > 0 ? bounds.height : 600
        let panelWidth = w / CGFloat(panels.count)
        for (i, panel) in panels.enumerated() {
            panel.frame = NSRect(x: CGFloat(i) * panelWidth, y: 0,
                                 width: panelWidth, height: h)
        }
    }

    /// A paneleket rácsos (négyzetes) elrendezésbe rendezi.
    func arrangeGrid() {
        guard !panels.isEmpty else { return }
        let w    = bounds.width  > 0 ? bounds.width  : 1000
        let h    = bounds.height > 0 ? bounds.height : 600
        let cols = Int(ceil(sqrt(Double(panels.count))))
        let rows = Int(ceil(Double(panels.count) / Double(cols)))
        let cellW = w / CGFloat(cols)
        let cellH = h / CGFloat(rows)
        for (i, panel) in panels.enumerated() {
            let col = i % cols
            let row = i / cols
            panel.frame = NSRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH,
                                 width: cellW, height: cellH)
        }
    }

    /// A paneleket egymásra halmozza (lapozható nézet); az utolsó kerül előtérbe.
    func arrangeTabbed() {
        guard !panels.isEmpty else { return }
        let w = bounds.width  > 0 ? bounds.width  : 1000
        let h = bounds.height > 0 ? bounds.height : 600
        let frame = NSRect(x: 0, y: 0, width: w, height: h)
        for panel in panels { panel.frame = frame }
        panels.last?.bringToFront()
    }

    // MARK: – Elrendezés mentése / betöltése

    /// Elmenti az összes panel pozícióját és méretét a UserDefaults-ba.
    func saveLayout() {
        let data = panels.map { p -> [String: Double] in
            [
                "x":      Double(p.frame.origin.x),
                "y":      Double(p.frame.origin.y),
                "width":  Double(p.frame.size.width),
                "height": Double(p.frame.size.height)
            ]
        }
        UserDefaults.standard.set(data, forKey: "VoxBarberWindowLayout")
    }

    /// Visszaállítja a korábban elmentett elrendezést.
    /// Csak az első min(panelek, mentett) darabot alkalmazza.
    func loadLayout() {
        guard let data = UserDefaults.standard.array(forKey: "VoxBarberWindowLayout")
                         as? [[String: Double]] else { return }
        let count = min(panels.count, data.count)
        for i in 0..<count {
            let d = data[i]
            let proposed = NSRect(
                x:      d["x"]      ?? 0,
                y:      d["y"]      ?? 0,
                width:  d["width"]  ?? 400,
                height: d["height"] ?? 280
            )
            panels[i].frame = constrainPanel(panels[i], to: proposed)
        }
    }

    // MARK: – Mozgatás korlátozása

    /// Visszaadja a javasolt keretet úgy korlátozva, hogy a panel teljes egészében
    /// a munkaterület határain belül maradjon.
    func constrainPanel(_ panel: DocumentPanelView, to proposed: NSRect) -> NSRect {
        return constrainRect(proposed, panelSize: proposed.size)
    }

    private func constrainRect(_ rect: NSRect, panelSize: NSSize) -> NSRect {
        let w = bounds.width  > 0 ? bounds.width  : 1000
        let h = bounds.height > 0 ? bounds.height : 600
        var f = rect
        f.origin.x = max(0, min(f.origin.x, w - panelSize.width))
        f.origin.y = max(0, min(f.origin.y, h - panelSize.height))
        return f
    }

    // MARK: – Átméretezés kezelése

    override func layout() {
        super.layout()
        // Ha az ablak kisebb lett, a kiszakadt paneleket visszahúzzuk
        for panel in panels {
            let constrained = constrainPanel(panel, to: panel.frame)
            if constrained != panel.frame {
                panel.frame = constrained
            }
        }
    }
}
