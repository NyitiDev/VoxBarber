import AppKit
import UniformTypeIdentifiers
import VoxBarberAudio

/// Az alkalmazás fődelegate-je.
/// Felelős az indításért, a menürendszer felépítéséért
/// és a főablakhoz való navigációért.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    // MARK: – Privát tulajdonságok

    private var splashWindowController: SplashWindowController?

    /// A főablak vezérlője – a splash bezárása után jön létre.
    var mainWindowController: MainWindowController?

    // MARK: – NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menürendszer felépítése az OS menüsorba
        buildMenuBar()

        // Splash képernyő megjelenítése az alkalmazás indításakor
        splashWindowController = SplashWindowController()
        splashWindowController?.onStart = { [weak self] in
            self?.showMainWindow()
        }
        splashWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Az alkalmazás akkor lép ki, ha az utolsó ablak is bezárul.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: – Főablak megjelenítése

    /// Létrehozza és megmutatja a főablakot, majd semmissé teszi a splash referenciát.
    func showMainWindow() {
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        splashWindowController = nil
    }

    // MARK: – Menürendszer felépítése

    private func buildMenuBar() {
        let menuBar = NSMenu()

        // ── Alkalmazás menü (VoxBarber) ──────────────────────────────────
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu(title: "VoxBarber")
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Névjegy – VoxBarber",
            action: #selector(showAbout),
            keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Kilépés a VoxBarberből",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        // ── Fájl menü ────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        menuBar.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "Fájl")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(NSMenuItem(
            title: "Új hangfájl",
            action: #selector(newAudioFile),
            keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(
            title: "Hangfájl megnyitása…",
            action: #selector(openAudioFile),
            keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem(
            title: "Hangfájl mentése…",
            action: #selector(saveAudioFile),
            keyEquivalent: "s"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Kilépés",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        // ── Szerkesztés menü ─────────────────────────────────────────────
        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Szerkesztés")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(
            title: "Másol",
            action: #selector(copyAudio),
            keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Kivág",
            action: #selector(cutAudio),
            keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Beilleszt",
            action: #selector(pasteAudio),
            keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Töröl",
            action: #selector(deleteAudio),
            keyEquivalent: ""))

        // ── Lejátszás menü ───────────────────────────────────────────────
        let playMenuItem = NSMenuItem()
        menuBar.addItem(playMenuItem)
        let playMenu = NSMenu(title: "Lejátszás")
        playMenuItem.submenu = playMenu

        playMenu.addItem(NSMenuItem(
            title: "Lejátszás az elejétől",
            action: #selector(playFromStart),
            keyEquivalent: ""))
        playMenu.addItem(NSMenuItem(
            title: "Kijelölt rész lejátszása",
            action: #selector(playSelection),
            keyEquivalent: ""))
        playMenu.addItem(NSMenuItem(
            title: "Lejátszás a kijelölt ponttól",
            action: #selector(playFromCursor),
            keyEquivalent: ""))

        // ── Nézet menü ───────────────────────────────────────────────────
        let viewMenuItem = NSMenuItem()
        menuBar.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "Nézet")
        viewMenuItem.submenu = viewMenu

        viewMenu.addItem(NSMenuItem(
            title: "Vízszintes ablak elrendezés",
            action: #selector(arrangeWindowsHorizontal),
            keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(
            title: "Négyzetes ablak elrendezés",
            action: #selector(arrangeWindowsGrid),
            keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(
            title: "Lapozott ablak elrendezés",
            action: #selector(arrangeWindowsTabbed),
            keyEquivalent: ""))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(
            title: "Ablak elrendezés mentése",
            action: #selector(saveWindowLayout),
            keyEquivalent: ""))
        viewMenu.addItem(NSMenuItem(
            title: "Ablak elrendezés betöltése",
            action: #selector(loadWindowLayout),
            keyEquivalent: ""))

        // ── Segítség menü ────────────────────────────────────────────────
        let helpMenuItem = NSMenuItem()
        menuBar.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Segítség")
        helpMenuItem.submenu = helpMenu

        helpMenu.addItem(NSMenuItem(
            title: "VoxBarber használata",
            action: #selector(showHelp),
            keyEquivalent: ""))
        helpMenu.addItem(NSMenuItem(
            title: "Szerzői jogok",
            action: #selector(showCopyright),
            keyEquivalent: ""))

        NSApp.mainMenu = menuBar
    }

    // MARK: – Menü akciók

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// Üres hangfájl panel megnyitása a főablakban.
    @objc func newAudioFile() {
        ensureMainWindow()
        mainWindowController?.workspaceView.addPanel(title: "Új hangfájl", fileURL: nil)
    }

    /// Fájlválasztó dialógus megjelenítése, majd a kiválasztott fájl panelként való megnyitása.
    @objc func openAudioFile() {
        ensureMainWindow()
        let panel = NSOpenPanel()
        panel.title = "Hangfájl megnyitása"
        panel.message = "Válasszon ki egy hangfájlt"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        // Engedélyezett hangformátumok
        panel.allowedContentTypes = [
            .audio,
            UTType(filenameExtension: "ogg") ?? .audio
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        mainWindowController?.workspaceView.addPanel(title: url.lastPathComponent, fileURL: url)
    }

    /// Hangfájl mentése – formátumválasztó dialógussal.
    @objc func saveAudioFile() {
        guard let panel = DocumentPanelView.focused else { return }

        // Formátum kiválasztása
        let alert = NSAlert()
        alert.messageText = "Mentési formátum"
        alert.informativeText = "Milyen formátumban mentse el a hangfájlt?"
        for fmt in ExportFormat.allCases {
            alert.addButton(withTitle: fmt.rawValue)
        }
        alert.addButton(withTitle: "Mégse")
        let response = alert.runModal()
        let formats = ExportFormat.allCases
        // Az NSAlert gombok 1000-től számozódnak
        let idx = response.rawValue - 1000
        guard idx >= 0, idx < formats.count else { return }
        let chosenFormat = formats[idx]

        // Célfájl kiválasztása
        let savePanel = NSSavePanel()
        savePanel.title = "Hangfájl mentése"
        savePanel.allowedContentTypes = []
        savePanel.nameFieldStringValue = (panel.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + chosenFormat.fileExtension
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try AudioEngine.shared.save(panel.audioBuffer, to: url, format: chosenFormat)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Mentési hiba"
            errAlert.informativeText = error.localizedDescription
            errAlert.runModal()
        }
    }

    // ── Lejátszás akciók (stub – hangmotor implementálásáig) ─────────────

    @objc private func playFromStart() {}
    @objc private func playSelection() {}
    @objc private func playFromCursor() {}

    // ── Szerkesztés akciók ────────────────────────────────────────────────

    @objc private func copyAudio() {
        DocumentPanelView.focused?.copyTapped()
    }
    @objc private func cutAudio() {
        DocumentPanelView.focused?.cutTapped()
    }
    @objc private func pasteAudio() {
        DocumentPanelView.focused?.pasteTapped()
    }
    @objc private func deleteAudio() {
        guard let panel = DocumentPanelView.focused,
              let range = panel.selectionRange else { return }
        panel.audioBuffer = panel.audioBuffer.deleting(from: range.start, to: range.end)
        panel.selectionRange = nil
    }

    // MARK: – Menü validáció

    /// Az AppKit minden menü megjelenítésekor meghívja ezt a metódust.
    /// Az egyes menüelemek csak akkor aktívak, ha a hozzájuk tartozó feltétel teljesül:
    ///  - Szerkesztés (Másol/Kivág/Töröl): aktív panel + van kijelölés
    ///  - Szerkesztés (Beilleszt): aktív panel (vágólap tartalom ellenőrzése hangmotor után)
    ///  - Lejátszás (mind): aktív panel létezik
    ///  - Kijelölt rész lejátszása: aktív panel + van kijelölés
    ///  - Hangfájl mentése: aktív panel létezik
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let panel = DocumentPanelView.focused
        let hasPanel = panel != nil
        let hasSelection = panel?.hasSelection ?? false

        switch menuItem.action {
        // Fájl
        case #selector(saveAudioFile):
            return hasPanel

        // Szerkesztés
        case #selector(copyAudio), #selector(cutAudio), #selector(deleteAudio):
            return hasSelection
        case #selector(pasteAudio):
            return hasPanel && AudioClipboard.shared.hasContent

        // Lejátszás
        case #selector(playFromStart), #selector(playFromCursor):
            return hasPanel
        case #selector(playSelection):
            return hasSelection

        // Nézet – elrendezések
        case #selector(arrangeWindowsHorizontal), #selector(arrangeWindowsGrid), #selector(arrangeWindowsTabbed):
            return hasPanel
        case #selector(saveWindowLayout):
            return hasPanel
        case #selector(loadWindowLayout):
            return UserDefaults.standard.object(forKey: "VoxBarberWindowLayout") != nil

        default:
            return true
        }
    }

    // ── Nézet akciók ─────────────────────────────────────────────────────

    @objc private func arrangeWindowsHorizontal() {
        mainWindowController?.workspaceView.arrangeHorizontal()
    }

    @objc private func arrangeWindowsGrid() {
        mainWindowController?.workspaceView.arrangeGrid()
    }

    @objc private func arrangeWindowsTabbed() {
        mainWindowController?.workspaceView.arrangeTabbed()
    }

    @objc private func saveWindowLayout() {
        mainWindowController?.workspaceView.saveLayout()
    }

    @objc private func loadWindowLayout() {
        mainWindowController?.workspaceView.loadLayout()
    }

    // ── Segítség akciók ───────────────────────────────────────────────────

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "VoxBarber használata"
        alert.informativeText = """
            Hangfájl megnyitása: Fájl › Hangfájl megnyitása (⌘O)
            Új hangfájl: Fájl › Új hangfájl (⌘N)
            A megnyíló paneleken lehet a hangfájlokat lejátszani és szerkeszteni.
            """
        alert.runModal()
    }

    @objc private func showCopyright() {
        let alert = NSAlert()
        alert.messageText = "Szerzői jogok"
        alert.informativeText = "© 2026 VoxBarber. Minden jog fenntartva."
        alert.runModal()
    }

    // MARK: – Segédfüggvény

    /// Biztosítja, hogy a főablak létezzen és látható legyen.
    private func ensureMainWindow() {
        if mainWindowController == nil {
            showMainWindow()
        }
    }
}
