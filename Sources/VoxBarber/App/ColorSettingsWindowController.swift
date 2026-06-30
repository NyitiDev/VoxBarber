import AppKit
import UniformTypeIdentifiers

/// A "Színek beállítása" ablak: felsorolja az app testreszabható színeit,
/// mindegyikhez egy színválasztó (NSColorWell) tartozik, alul Mentés / Betöltés
/// / Bezárás gombokkal. A színek azonnal érvénybe lépnek a `ThemeManager`-en át.
@MainActor
final class ColorSettingsWindowController: NSWindowController, NSWindowDelegate {

    /// A VBC (VoxBarber Colors) fájlok típusa – JSON tartalommal.
    private static let vbcType: UTType = UTType(filenameExtension: "vbc") ?? .json

    /// A sorok definíciója: megjelenített név + a téma adott színére mutató kulcs.
    private enum ColorKey: CaseIterable {
        case background, button, waveform, marker, selection, label

        var title: String {
            switch self {
            case .background: return "Háttérszín"
            case .button:     return "Gombok színe"
            case .waveform:   return "Hanghullám színe"
            case .marker:     return "Jelölő vonal színe"
            case .selection:  return "Kijelölés színe"
            case .label:      return "Feliratok színe"
            }
        }

        func color(from t: ThemeColors) -> RGBAColor {
            switch self {
            case .background: return t.background
            case .button:     return t.button
            case .waveform:   return t.waveform
            case .marker:     return t.marker
            case .selection:  return t.selection
            case .label:      return t.label
            }
        }
    }

    private var wells: [ColorKey: NSColorWell] = [:]

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        win.title = "Színek beállítása"
        win.isReleasedWhenClosed = false
        win.level = .floating
        self.init(window: win)
        win.delegate = self
        buildContent()
        win.center()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let theme = ThemeManager.shared.colors
        let rowStack = NSStackView()
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        for key in ColorKey.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: key.title)
            label.font = NSFont.systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 200).isActive = true

            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.color = key.color(from: theme).nsColor
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 60).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            wells[key] = well

            row.addArrangedSubview(label)
            row.addArrangedSubview(well)
            rowStack.addArrangedSubview(row)
        }

        // Alsó gombsor
        let saveBtn  = NSButton(title: "Mentés",   target: self, action: #selector(saveTapped))
        let loadBtn  = NSButton(title: "Betöltés", target: self, action: #selector(loadTapped))
        let closeBtn = NSButton(title: "Bezárás",  target: self, action: #selector(closeTapped))
        closeBtn.keyEquivalent = "\u{1b}"   // Esc
        for b in [saveBtn, loadBtn, closeBtn] { b.bezelStyle = .rounded }

        let buttonRow = NSStackView(views: [saveBtn, loadBtn, closeBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [rowStack, buttonRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .trailing
        mainStack.spacing = 20
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    /// Egy színkút értékét az aktuális témára alkalmazza.
    @objc private func colorChanged(_ sender: NSColorWell) {
        var theme = ThemeManager.shared.colors
        for (key, well) in wells where well === sender {
            let c = RGBAColor(sender.color)
            switch key {
            case .background: theme.background = c
            case .button:     theme.button = c
            case .waveform:   theme.waveform = c
            case .marker:     theme.marker = c
            case .selection:  theme.selection = c
            case .label:      theme.label = c
            }
        }
        ThemeManager.shared.update(theme)
    }

    /// Frissíti a színkutakat az aktuális téma alapján (pl. betöltés után).
    private func refreshWells() {
        let theme = ThemeManager.shared.colors
        for (key, well) in wells {
            well.color = key.color(from: theme).nsColor
        }
    }

    @objc private func saveTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.vbcType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Színek.vbc"
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, var url = panel.url else { return }
            if url.pathExtension.lowercased() != "vbc" {
                url.deletePathExtension()
                url.appendPathExtension("vbc")
            }
            do {
                try ThemeManager.shared.save(to: url)
            } catch {
                self.presentError(error, title: "Nem sikerült elmenteni a színeket")
            }
        }
        if let win = window {
            panel.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    @objc private func loadTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [Self.vbcType]
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ThemeManager.shared.load(from: url)
                self.refreshWells()
            } catch {
                self.presentError(error, title: "Nem sikerült betölteni a színeket")
            }
        }
        if let win = window {
            panel.beginSheetModal(for: win, completionHandler: complete)
        } else {
            complete(panel.runModal())
        }
    }

    @objc private func closeTapped() {
        window?.close()
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let win = window {
            alert.beginSheetModal(for: win, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
