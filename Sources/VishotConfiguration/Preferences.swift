import Foundation
import VishotRendering

public enum AppearancePreference: String, CaseIterable {
    case system, light, dark
    public var label: String { rawValue.capitalized }
    public func resolve(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum ColorScheme: Equatable {
    case light, dark
}

/// Selectable preference identity. GUI definitions and resolved drawing styles live elsewhere.
public enum VisualStyle: String, CaseIterable {
    case pixel, smooth

    public var label: String { rawValue.capitalized }
    public var annotationID: ThemeID {
        switch self {
        case .pixel: return .pixel
        case .smooth: return .clean
        }
    }

    public init(annotationID: ThemeID) {
        switch annotationID {
        case .pixel: self = .pixel
        case .clean: self = .smooth
        }
    }
}

public enum HistoryRetention: Int, CaseIterable {
    case off = 0, oneDay = 1, threeDays = 3, sevenDays = 7, thirtyDays = 30
    public var label: String { self == .off ? "Off" : "\(rawValue) \(rawValue == 1 ? "day" : "days")" }
}
