import SwiftUI
import AppKit

/// The five user-selectable appearance modes. Persisted as the raw string in the existing
/// `"appearance"` UserDefaults key, so older values (System/Light/Dark) keep working and any
/// unknown value falls back to `.system`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case paperyLight = "Papery Light"
    case paperyDark = "Papery Dark"

    var id: String { rawValue }
    var label: String { rawValue }

    init(_ raw: String) { self = AppearanceMode(rawValue: raw) ?? .system }

    /// System appearance (`NSAppearance`) that should underlie this mode so native controls
    /// (segmented picker, checkboxes) stay legible. Papery modes ride on top of aqua/darkAqua.
    var underlyingScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .paperyLight: return .light
        case .dark, .paperyDark: return .dark
        }
    }

    var isDarkPaper: Bool { self == .paperyDark }
    var isPapery: Bool { self == .paperyLight || self == .paperyDark }
}

/// A resolved set of colors and flags the SwiftUI views consume instead of raw system materials.
/// System/Light/Dark keep the native look (translucent material + system control colors); the two
/// Papery modes swap in solid warm parchment / charcoal-paper palettes with ink-like text.
struct Theme {
    /// When true the root uses `.regularMaterial` (native look). Papery uses a solid `background`.
    let usesMaterial: Bool
    let background: Color
    let surface: Color
    let surfaceBorder: Color
    let field: Color
    let fieldBorder: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let consoleBackground: Color
    let consoleBorder: Color
    let warning: Color
    /// A faint grain overlay opacity for the papery texture (0 for non-papery modes).
    let grainOpacity: Double

    /// Native (System/Light/Dark) theme: keep system materials and semantic colors so the app
    /// looks exactly as before for those modes.
    static func native(dark: Bool) -> Theme {
        Theme(
            usesMaterial: true,
            background: .clear,
            surface: Color(nsColor: .controlBackgroundColor),
            surfaceBorder: .primary.opacity(0.07),
            field: .primary.opacity(0.05),
            fieldBorder: .primary.opacity(0.07),
            text: .primary,
            secondaryText: .secondary,
            tertiaryText: Color.primary.opacity(dark ? 0.35 : 0.4),
            accent: Color(red: 0.878, green: 0.584, blue: 0.184), // #e0952f
            consoleBackground: Color(nsColor: .textBackgroundColor),
            consoleBorder: .primary.opacity(0.1),
            // The system `.orange` (#FF9500) is too light to read on white/light backgrounds.
            // Use a darker burnt-orange on light, and the brighter orange on dark.
            warning: dark ? Color(red: 1.0, green: 0.624, blue: 0.235)   // #FF9F3C
                          : Color(red: 0.700, green: 0.365, blue: 0.0),  // #B35D00
            grainOpacity: 0
        )
    }

    static let paperyLight = Theme(
        usesMaterial: false,
        background: Color(red: 0.957, green: 0.925, blue: 0.847),   // #f4ecd8 parchment
        surface: Color(red: 0.980, green: 0.961, blue: 0.902),      // #faf5e6 lighter card
        surfaceBorder: Color(red: 0.804, green: 0.741, blue: 0.620).opacity(0.55), // warm border
        field: Color(red: 0.933, green: 0.898, blue: 0.812),        // #eee5cf field
        fieldBorder: Color(red: 0.804, green: 0.741, blue: 0.620).opacity(0.5),
        text: Color(red: 0.227, green: 0.192, blue: 0.157),         // #3a3128 ink
        secondaryText: Color(red: 0.376, green: 0.329, blue: 0.271),// #605448
        tertiaryText: Color(red: 0.510, green: 0.451, blue: 0.376), // #82735f
        accent: Color(red: 0.776, green: 0.486, blue: 0.149),       // #c67c26 deeper amber for cream
        consoleBackground: Color(red: 0.988, green: 0.973, blue: 0.929), // near-paper white
        consoleBorder: Color(red: 0.804, green: 0.741, blue: 0.620).opacity(0.6),
        warning: Color(red: 0.702, green: 0.373, blue: 0.086),      // warm burnt-orange
        grainOpacity: 0.05
    )

    static let paperyDark = Theme(
        usesMaterial: false,
        background: Color(red: 0.149, green: 0.133, blue: 0.110),   // #26221c charcoal paper
        surface: Color(red: 0.188, green: 0.165, blue: 0.133),      // #302a22 card
        surfaceBorder: Color(red: 0.878, green: 0.831, blue: 0.729).opacity(0.12),
        field: Color(red: 0.220, green: 0.196, blue: 0.157),        // #383228 field
        fieldBorder: Color(red: 0.878, green: 0.831, blue: 0.729).opacity(0.14),
        text: Color(red: 0.925, green: 0.890, blue: 0.816),         // #ece3d0 warm off-white
        secondaryText: Color(red: 0.741, green: 0.702, blue: 0.627),// #bdb3a0
        tertiaryText: Color(red: 0.573, green: 0.537, blue: 0.471), // #92897866
        accent: Color(red: 0.878, green: 0.584, blue: 0.184),       // #e0952f amber
        consoleBackground: Color(red: 0.114, green: 0.102, blue: 0.082), // #1d1a15
        consoleBorder: Color(red: 0.878, green: 0.831, blue: 0.729).opacity(0.15),
        warning: Color(red: 0.902, green: 0.588, blue: 0.302),      // warm amber-orange
        grainOpacity: 0.06
    )

    /// Resolve a theme from the stored appearance string. `systemIsDark` is the effective system
    /// scheme, used only when mode is `.system` to pick the matching native palette.
    static func resolve(_ mode: AppearanceMode, systemIsDark: Bool) -> Theme {
        switch mode {
        case .paperyLight: return .paperyLight
        case .paperyDark: return .paperyDark
        case .system: return .native(dark: systemIsDark)
        case .light: return .native(dark: false)
        case .dark: return .native(dark: true)
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .native(dark: false)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
