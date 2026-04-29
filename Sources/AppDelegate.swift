import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var splashWindowController: SplashWindowController?
    /// The single persistent hub window – referenced by AudioDocument.makeWindowControllers().
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMainMenu()

        splashWindowController = SplashWindowController()
        splashWindowController?.showWindow(nil)
        splashWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Called by SplashWindowController when the user taps "Get Started"
    func splashDidFinish() {
        splashWindowController?.close()
        splashWindowController = nil

        let hub = MainWindowController()
        mainWindowController = hub
        hub.showWindow(nil)
        hub.window?.makeKeyAndOrderFront(nil)
    }

    // Called when a file is opened via Finder / drag-to-Dock
    // (AudioDocument.makeWindowControllers redirects here)

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu ───────────────────────────────────────────────────
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "VoxBarber")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About VoxBarber",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit VoxBarber",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ── File menu ──────────────────────────────────────────────────
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let openItem = NSMenuItem(title: "Open\u{2026}",
                                  action: #selector(openFromMenu),
                                  keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)

        // ── Window menu ────────────────────────────────────────────────
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.miniaturize(_:)),
                        keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom",
                        action: #selector(NSWindow.zoom(_:)),
                        keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    @objc private func openFromMenu() {
        // Route to the hub window's open handler
        mainWindowController?.openDocument(nil)
    }
}
