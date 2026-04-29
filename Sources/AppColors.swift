import AppKit

/// Central colour palette – single source of truth for the dark UI.
enum AppColors {
    /// Near-black window background  #1C1C1E
    static let background  = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)
    /// Slightly lighter surface      #2C2C2E
    static let surface     = NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1)
    /// Orange accent                 #FF9F0A
    static let accent      = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Selection fill (semi-transparent accent)
    static let selection   = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 0.22)
    /// Primary text
    static let textPrimary = NSColor.white
    /// Secondary / dimmed text
    static let textSecondary = NSColor.white.withAlphaComponent(0.45)
    /// Thin separator line
    static let separator   = NSColor.white.withAlphaComponent(0.10)
}
