import AppKit
import SwiftUI

public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The color used for buttons, links, and chart marks, chosen in Settings.
public enum AccentChoice: String, CaseIterable, Identifiable {
    case clay
    case green
    case blue
    case plum
    case slate

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .clay: return "Clay"
        case .green: return "Green"
        case .blue: return "Blue"
        case .plum: return "Plum"
        case .slate: return "Slate"
        }
    }

    /// Light and dark accent, then light and dark chart marks (a little softer in dark mode).
    fileprivate var values: (light: (Double, Double, Double), dark: (Double, Double, Double),
                             chartDark: (Double, Double, Double)) {
        switch self {
        case .clay: return ((0.561, 0.208, 0.180), (0.871, 0.490, 0.439), (0.769, 0.408, 0.361))
        case .green: return ((0.157, 0.431, 0.282), (0.435, 0.769, 0.553), (0.369, 0.678, 0.478))
        case .blue: return ((0.169, 0.341, 0.569), (0.502, 0.651, 0.894), (0.420, 0.569, 0.812))
        case .plum: return ((0.447, 0.204, 0.420), (0.788, 0.537, 0.780), (0.698, 0.459, 0.690))
        case .slate: return ((0.278, 0.329, 0.388), (0.639, 0.690, 0.749), (0.553, 0.604, 0.663))
        }
    }

    static let preferenceKey = "accentChoice"
    static var current: AccentChoice = UserDefaults.standard.string(forKey: preferenceKey)
        .flatMap(AccentChoice.init(rawValue:)) ?? .clay
}

enum Theme {
    static let paper = dynamic(light: (0.969, 0.949, 0.910), dark: (0.110, 0.102, 0.094))
    static let card = dynamic(light: (0.996, 0.988, 0.969), dark: (0.161, 0.149, 0.137))
    static let line = dynamic(light: (0.867, 0.835, 0.776), dark: (0.267, 0.247, 0.224))
    /// Computed, so views that redraw after the choice changes (any view watching the model) pick it up.
    static var accent: Color { swatch(AccentChoice.current) }
    static let notice = dynamic(light: (0.898, 0.953, 0.906), dark: (0.110, 0.200, 0.141))
    /// Warnings and words a reading wasn't sure of.
    static let highlight = dynamic(light: (0.180, 0.545, 0.341), dark: (0.400, 0.780, 0.525))
    /// Chart marks, validated for contrast and lightness against both card surfaces.
    static var chart: Color {
        let values = AccentChoice.current.values
        return dynamic(light: values.light, dark: values.chartDark)
    }
    /// Colors for comparing several words in one chart: the chart color first, then ones far from it and each other.
    static func series(_ index: Int) -> Color {
        if index == 0 { return chart }
        let others: [(light: (Double, Double, Double), dark: (Double, Double, Double))] = [
            ((0.145, 0.459, 0.651), (0.416, 0.690, 0.871)),
            ((0.769, 0.522, 0.075), (0.894, 0.722, 0.337)),
            ((0.180, 0.545, 0.341), (0.400, 0.780, 0.525)),
            ((0.478, 0.302, 0.659), (0.706, 0.580, 0.890)),
            ((0.737, 0.247, 0.420), (0.894, 0.522, 0.639)),
        ]
        // Leave out the one too close to the chosen theme color.
        let close: Int? = switch AccentChoice.current {
        case .blue: 0
        case .green: 2
        case .plum: 3
        case .clay: 4
        case .slate: nil
        }
        let usable = others.enumerated().filter { $0.offset != close }.map(\.element)
        let choice = usable[(index - 1) % usable.count]
        return dynamic(light: choice.light, dark: choice.dark)
    }

    /// The accent as it would look in a given choice, for the swatches in Settings.
    static func swatch(_ choice: AccentChoice) -> Color {
        dynamic(light: choice.values.light, dark: choice.values.dark)
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}
