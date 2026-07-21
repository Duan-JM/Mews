import Foundation

struct NotchAccessibilityPreferences: Equatable {
    let reduceMotion: Bool
    let increaseContrast: Bool
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
