import AppKit

/// Egy sRGB szín, amely JSON-ba (VBC fájl) szerializálható.
struct RGBAColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        r = Double(c.redComponent)
        g = Double(c.greenComponent)
        b = Double(c.blueComponent)
        a = Double(c.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Az app használatban lévő, felhasználó által testreszabható színei.
struct ThemeColors: Codable, Equatable {
    var background: RGBAColor   // háttérszín
    var button:     RGBAColor   // gombok színe
    var waveform:   RGBAColor   // hanghullám színe
    var marker:     RGBAColor   // jelölő vonal színe
    var selection:  RGBAColor   // kijelölés színe
    var label:      RGBAColor   // feliratok színe

    /// A gyári alapértelmezett színek (megegyeznek a kód eredeti értékeivel).
    static let `default` = ThemeColors(
        background: RGBAColor(r: 0.09, g: 0.09, b: 0.11, a: 1.0),
        button:     RGBAColor(r: 0.82, g: 0.84, b: 0.90, a: 1.0),
        waveform:   RGBAColor(r: 0.25, g: 0.65, b: 1.0,  a: 0.85),
        marker:     RGBAColor(r: 0.0,  g: 0.95, b: 0.55, a: 1.0),
        selection:  RGBAColor(r: 0.30, g: 0.58, b: 1.0,  a: 0.28),
        label:      RGBAColor(r: 0.85, g: 0.93, b: 1.0,  a: 1.0)
    )
}

/// Globális színkezelő: tárolja az aktuális témát, perzisztálja a beállításokba,
/// és értesíti a nézeteket, ha a színek megváltoznak.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    /// Értesítés, amelyet a színek megváltozásakor küldünk.
    static let changedNotification = Notification.Name("VoxBarberThemeColorsChanged")

    private let defaultsKey = "VoxBarberThemeColors"

    private(set) var colors: ThemeColors

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ThemeColors.self, from: data) {
            colors = decoded
        } else {
            colors = .default
        }
    }

    /// Frissíti az aktuális színeket, elmenti a beállításokba és értesíti a nézeteket.
    func update(_ newColors: ThemeColors) {
        colors = newColors
        persist()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(colors) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Elmenti az aktuális színeket egy VBC (JSON) fájlba.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(colors)
        try data.write(to: url, options: .atomic)
    }

    /// Betölt egy VBC (JSON) fájlból színeket, és alkalmazza azokat.
    func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ThemeColors.self, from: data)
        update(decoded)
    }
}
