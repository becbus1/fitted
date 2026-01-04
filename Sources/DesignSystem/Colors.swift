import SwiftUI

// TEMP scaffolding: shared color tokens.
// Replace later with final palette.
enum FittedColors {
    // MARK: - Backgrounds
    static let backgroundPrimary = Color(.systemBackground)
    static let backgroundSecondary = Color(.secondarySystemBackground)

    // MARK: - Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(.tertiaryLabel)

    // MARK: - Accents
    static let accent = Color(red: 0.22, green: 0.24, blue: 0.27)

    // MARK: - Fills
    static let fillInactive = Color(red: 0.86, green: 0.87, blue: 0.89)

    // MARK: - Separators
    static let separator = Color(.separator)
}
