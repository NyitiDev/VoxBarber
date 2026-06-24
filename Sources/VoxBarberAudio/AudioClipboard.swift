import Foundation

public extension Notification.Name {
    static let audioClipboardDidChange = Notification.Name("AudioClipboardDidChange")
}

/// App-szintű belső vágólap hangadatokhoz.
///
/// Az OS rendszer-vágólapját nem használjuk PCM adatokra, mert az
/// nem tud hatékonyan nagy lebegőpontos tömböket tárolni.
/// Ez a singleton tárolja az utolsó Copy / Cut művelet eredményét,
/// és a Paste művelet innen veszi ki az adatot.
@MainActor
public final class AudioClipboard {

    // MARK: – Singleton

    public static let shared = AudioClipboard()
    private init() {}

    // MARK: – Tartalom

    /// A legutóbb másolt / kivágott hangpuffer.
    /// `nil`, ha még nem történt Copy/Cut.
    public private(set) var buffer: AudioBuffer?

    /// Annak a panelnek az UUID-ja, amelyből a vágólapon levő adat származik.
    public private(set) var sourcePanelID: UUID?

    /// Igaz, ha a vágólapon van tartalom (a Paste menüelem engedélyezéséhez).
    public var hasContent: Bool { buffer != nil }

    // MARK: – Műveletek

    /// Elmenti a puffert a vágólapra (Copy / Cut közös logika).
    /// - Parameters:
    ///   - buffer: A tárolni kívánt hangpuffer.
    ///   - sourcePanelID: A forrás panel UUID-ja; bezáráskor ellenőrzendő.
    public func store(_ buffer: AudioBuffer, sourcePanelID: UUID? = nil) {
        self.buffer = buffer
        self.sourcePanelID = sourcePanelID
        NotificationCenter.default.post(name: .audioClipboardDidChange, object: self)
    }

    /// Visszaadja a vágólap tartalmát anélkül, hogy törölné.
    public func peek() -> AudioBuffer? {
        return buffer
    }

    /// Törli a vágólap tartalmát.
    public func clear() {
        buffer = nil
        sourcePanelID = nil
        NotificationCenter.default.post(name: .audioClipboardDidChange, object: self)
    }
}
