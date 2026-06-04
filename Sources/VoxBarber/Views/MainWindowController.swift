import AppKit

/// A VoxBarber főablak vezérlője.
///
/// 1200×800 px méretű (vagy az OS által engedélyezett legnagyobb) ablak,
/// amely átméretezhető és mozgatható. Tartalmazza a `WorkspaceView`-t,
/// amelyen belül a dokumentum panelek jelennek meg.
@MainActor
final class MainWindowController: NSWindowController {

    /// A munkaterület nézet – közvetlen elérést biztosít a panel-kezeléshez.
    private(set) var workspaceView: WorkspaceView!

    // MARK: – Inicializálás

    convenience init() {
        // Az ablak mérete: ideálisan 1200×800, de az elérhető képernyőterülethez igazítva
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width  = min(1200.0, screenFrame.width)
        let height = min(800.0,  screenFrame.height)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxBarber"
        window.minSize = NSSize(width: 640, height: 420)
        window.center()

        self.init(window: window)
        buildWorkspace()
    }

    // MARK: – Munkaterület felépítése

    private func buildWorkspace() {
        guard let contentView = window?.contentView else { return }

        workspaceView = WorkspaceView()
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(workspaceView)

        // A WorkspaceView kitölti a teljes content area-t
        NSLayoutConstraint.activate([
            workspaceView.topAnchor.constraint(equalTo: contentView.topAnchor),
            workspaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            workspaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            workspaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
}
