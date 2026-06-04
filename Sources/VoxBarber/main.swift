import AppKit

// VoxBarber alkalmazás belépési pontja.
// Létrehozza az NSApplication singleton-t, beállítja az aktivációs házirendet
// (regular = dokk ikon + alkalmazás menü), hozzárendeli a delegate-t, majd elindítja a főciklust.

// MainActor.assumeIsolated: a main.swift tetőszintű kódja a főszálon fut,
// ezt jelezzük a fordítónak, hogy @MainActor-izolált típusokat is létre tudjunk hozni.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let appDelegate = AppDelegate()
    app.delegate = appDelegate

    app.run()
}
