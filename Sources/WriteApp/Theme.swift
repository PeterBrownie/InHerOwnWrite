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

enum Theme {
    static let paper = dynamic(light: (0.969, 0.949, 0.910), dark: (0.110, 0.102, 0.094))
    static let card = dynamic(light: (0.996, 0.988, 0.969), dark: (0.161, 0.149, 0.137))
    static let line = dynamic(light: (0.867, 0.835, 0.776), dark: (0.267, 0.247, 0.224))
    static let accent = dynamic(light: (0.561, 0.208, 0.180), dark: (0.871, 0.490, 0.439))
    static let notice = dynamic(light: (0.984, 0.925, 0.847), dark: (0.290, 0.204, 0.114))
    /// Chart marks, validated for contrast and lightness against both card surfaces.
    static let chart = dynamic(light: (0.561, 0.208, 0.180), dark: (0.769, 0.408, 0.361))

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}
