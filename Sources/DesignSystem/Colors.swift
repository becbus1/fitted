import SwiftUI

// MARK: - Fitted Color System
// Design philosophy: Quiet Native Social
// Colors should feel like iOS system UI, not brand expression.
// The palette is intentionally restrained to reduce visual noise
// and create a calm, non-performative environment.

/// Centralized color definitions for the Fitted app.
/// All UI components must consume colors from this namespace.
/// Do not use Color literals or system colors directly in views.
enum FittedColors {

    // MARK: - Text Colors
    // Using semantic system colors ensures proper contrast
    // and automatic light/dark mode adaptation.

    /// Primary text: headlines, key statements, names.
    /// System primary label provides optimal readability.
    static let textPrimary = Color.primary

    /// Secondary text: body copy, descriptions.
    /// Slightly receded but fully legible.
    static let textSecondary = Color.secondary

    /// Tertiary text: captions, helper text, social nudges.
    /// Visually quieter but maintains WCAG contrast.
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    // MARK: - Background Colors
    // Backgrounds use grouped system colors for native feel.
    // Avoids pure white/black for softer appearance.

    /// Primary background: main content areas.
    static let backgroundPrimary = Color(uiColor: .systemBackground)

    /// Secondary background: cards, grouped content.
    static let backgroundSecondary = Color(uiColor: .secondarySystemBackground)

    /// Tertiary background: nested elements, subtle differentiation.
    static let backgroundTertiary = Color(uiColor: .tertiarySystemBackground)

    // MARK: - Separators
    // Subtle dividers, never prominent.

    /// Standard separator for lists and sections.
    static let separator = Color(uiColor: .separator)

    /// Opaque separator when layering requires it.
    static let separatorOpaque = Color(uiColor: .opaqueSeparator)

    // MARK: - Accent Color
    // Single accent for progress, completion, and focus states.
    // Slate/graphite blue-gray: informational, stable, emotionally neutral.
    // Never used for rewards, celebrations, or urgency.

    /// Muted blue-gray accent for progress rings and selection state.
    /// Intentionally desaturated to avoid feeling evaluative or expressive.
    static let accent = Color("AccentSlate", bundle: .main)

    /// Fallback accent using system gray with slight blue bias.
    /// Used if asset catalog color is unavailable.
    static let accentFallback = Color(uiColor: UIColor { traits in
        // Light mode: slate gray with subtle cool undertone
        // Dark mode: slightly lifted for visibility, still muted
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1.0)
            : UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1.0)
    })

    // MARK: - Functional Colors
    // Minimal set for specific UI states.
    // No error red, warning yellow, or success green in MVP.
    // Absence is shown through incompleteness, not color coding.

    /// Fill color for inactive/unposted member avatars.
    /// Subtle placeholder, never shaming.
    static let fillInactive = Color(uiColor: .quaternarySystemFill)

    /// Fill color for posted/complete states.
    /// Uses accent to indicate progress without celebration.
    static let fillComplete = accent
}

// MARK: - Design Notes
//
// Why no pure black/white:
// System colors automatically use off-white (#F2F2F7) in light mode
// and near-black (#1C1C1E) in dark mode, creating softer contrast.
//
// Why blue-gray accent:
// - Reads as "system status" not "brand"
// - Emotionally neutral, doesn't reward or punish
// - Works for progress without feeling celebratory
// - Matte appearance aligns with Quiet Native Social aesthetic
//
// Why no additional colors:
// - Reduces cognitive load
// - Prevents gamification creep
// - Forces UI to communicate through structure, not color
