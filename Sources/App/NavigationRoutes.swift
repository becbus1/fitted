import Foundation

// MARK: - Navigation Routes
// Typed routes for NavigationStack paths.
// Each phase has its own route enum to prevent invalid states.

/// Routes available during onboarding phase.
/// Minimal: just the philosophy screen.
enum OnboardingRoute: Hashable {
    /// Initial philosophy screen with Create/Join options.
    case welcome
}

/// Routes available in noCircle phase.
/// User must create or join before proceeding.
enum CircleSetupRoute: Hashable {
    /// Create a new circle flow.
    case createCircle

    /// Join existing circle via code/link.
    case joinCircle
}

/// Routes available when user is in a circle.
/// The main app experience.
enum CircleRoute: Hashable {
    /// Circle home: ring, member status, today's state.
    case home

    /// Daily post capture flow (presented modally).
    case post

    /// Personal archive/closet.
    case archive

    /// Circle settings (future).
    case settings
}

// MARK: - Route Type Erasure
// For cases where we need heterogeneous navigation.

/// Wrapper for any route type.
/// Enables mixed-type navigation stacks if needed.
enum AnyRoute: Hashable {
    case onboarding(OnboardingRoute)
    case circleSetup(CircleSetupRoute)
    case circle(CircleRoute)
}
