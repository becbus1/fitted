import SwiftUI

// MARK: - Fitted Typography System
// Design philosophy: Quiet Native Social
// Text should whisper, not shout. Typography creates hierarchy
// through subtle size and weight differences, never through
// bold emphasis or decorative treatment.

/// Centralized typography definitions for the Fitted app.
/// Exactly three semantic text styles. No exceptions.
/// All UI components must consume fonts from this namespace.
enum FittedTypography {

    // MARK: - Primary
    // Screen titles, key statements, circle names.
    // Calm and clear, not bold or attention-grabbing.
    // Uses medium weight for subtle emphasis without shouting.

    /// Primary text style for titles and key statements.
    /// 20pt medium — prominent but restrained.
    static let primary = Font.system(size: 20, weight: .medium, design: .default)

    // MARK: - Body
    // Main explanatory text, descriptions, member names.
    // Regular weight for comfortable extended reading.
    // This is the workhorse style for most UI text.

    /// Body text style for main content.
    /// 17pt regular — iOS default body size, familiar and readable.
    static let body = Font.system(size: 17, weight: .regular, design: .default)

    // MARK: - Caption
    // Helper text, social proof nudges, timestamps, footnotes.
    // Visually recedes but maintains legibility.
    // Paired with textTertiary color for full effect.

    /// Caption text style for secondary information.
    /// 13pt regular — quiet but accessible.
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
}

// MARK: - Text Style View Modifier
// Convenience modifier combining font and color for each semantic style.
// Ensures consistent pairing throughout the app.

extension View {

    /// Applies primary text styling: larger, medium weight, primary color.
    /// Use for screen titles and key statements.
    func textStylePrimary() -> some View {
        self
            .font(FittedTypography.primary)
            .foregroundStyle(FittedColors.textPrimary)
    }

    /// Applies body text styling: standard size, regular weight, secondary color.
    /// Use for main explanatory content.
    func textStyleBody() -> some View {
        self
            .font(FittedTypography.body)
            .foregroundStyle(FittedColors.textSecondary)
    }

    /// Applies caption text styling: smaller, lighter, tertiary color.
    /// Use for helper text, social nudges, timestamps.
    func textStyleCaption() -> some View {
        self
            .font(FittedTypography.caption)
            .foregroundStyle(FittedColors.textTertiary)
    }
}

// MARK: - Design Notes
//
// Why exactly 3 styles:
// - Reduces decision fatigue for developers
// - Prevents typography sprawl over time
// - Forces clear content hierarchy decisions
// - Aligns with "max 3 font sizes per screen" constraint
//
// Why no bold:
// - Bold text signals urgency or importance
// - This app avoids urgency by design
// - Medium weight provides enough hierarchy
// - Bold would conflict with "text should whisper" principle
//
// Why system fonts only:
// - SF Pro is designed for iOS legibility
// - Custom fonts add brand expression we're avoiding
// - System fonts get automatic optical sizing
// - Reduces app bundle size
//
// Size rationale:
// - 20pt primary: ~1.18x body, subtle step up
// - 17pt body: iOS standard, universally comfortable
// - 13pt caption: smallest legible size, clearly secondary
//
// These three styles handle all Fitted UI needs:
// - Onboarding headlines → primary
// - Philosophy text → body
// - "4/5 posted today" → caption
// - Member names → body
// - "Waiting on 1" → caption
