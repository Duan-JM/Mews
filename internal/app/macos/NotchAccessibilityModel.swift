import Foundation
import SwiftUI

struct NotchAccessibilityPreferences: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
}

enum NotchSurfaceTreatment: Equatable {
    case solidBlack
    case adaptiveMaterial
    case opaqueFallback

    static func resolved(
        placementMode: OverlayPlacementMode,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> NotchSurfaceTreatment {
        guard placementMode == .topCenter else {
            return .solidBlack
        }
        if reduceTransparency || increaseContrast {
            return .opaqueFallback
        }
        return .adaptiveMaterial
    }
}

struct NotchSurfacePalette {
    let foreground: Color
    let inverseForeground: Color
    let opaqueBackground: Color
    let materialTint: Color
    let outerBorder: Double

    static func resolved(
        placementMode: OverlayPlacementMode,
        colorScheme: ColorScheme,
        increaseContrast: Bool
    ) -> NotchSurfacePalette {
        guard placementMode == .topCenter else {
            return NotchSurfacePalette(
                foreground: .white,
                inverseForeground: .black,
                opaqueBackground: .black,
                materialTint: .clear,
                outerBorder: 0
            )
        }

        let isDark = colorScheme == .dark
        return NotchSurfacePalette(
            foreground: isDark
                ? .white
                : Color(red: 0.075, green: 0.082, blue: 0.094),
            inverseForeground: isDark ? .black : .white,
            opaqueBackground: isDark
                ? Color(red: 0.095, green: 0.102, blue: 0.112)
                : Color(red: 0.95, green: 0.952, blue: 0.958),
            materialTint: isDark
                ? Color.black.opacity(0.18)
                : Color.white.opacity(0.28),
            outerBorder: increaseContrast ? 0.5 : (isDark ? 0.24 : 0.18)
        )
    }
}

struct NotchContrastPalette: Equatable {
    let badgeText: Double
    let metadataText: Double
    let primaryText: Double
    let secondaryText: Double
    let mutedText: Double
    let separator: Double
    let border: Double
    let disabledText: Double
    let disabledSurface: Double
    let disabledBorder: Double
    let statusFloor: Double

    static func resolved(increaseContrast: Bool) -> NotchContrastPalette {
        if increaseContrast {
            return NotchContrastPalette(
                badgeText: 1,
                metadataText: 0.82,
                primaryText: 1,
                secondaryText: 0.84,
                mutedText: 0.64,
                separator: 0.34,
                border: 0.58,
                disabledText: 0.58,
                disabledSurface: 0.14,
                disabledBorder: 0.42,
                statusFloor: 0.78
            )
        }
        return NotchContrastPalette(
            badgeText: 0.78,
            metadataText: 0.5,
            primaryText: 0.92,
            secondaryText: 0.58,
            mutedText: 0.34,
            separator: 0.1,
            border: 0.22,
            disabledText: 0.34,
            disabledSurface: 0.06,
            disabledBorder: 0.1,
            statusFloor: 0
        )
    }
}
