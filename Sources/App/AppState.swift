import SwiftUI

// MARK: - App State
// Central state container for navigation decisions.
// Determines which root experience the user sees.
// MVVM-friendly: views observe this, ViewModels mutate it.

/// The user's current position in the app lifecycle.
/// Determines root-level navigation branching.
enum AppPhase: Equatable {
    /// First launch, no onboarding completed.
    /// User must understand the product philosophy.
    case onboarding

    /// Onboarding complete, but no circle membership.
    /// User must create or join a circle to proceed.
    case noCircle

    /// User belongs to at least one circle.
    /// Full app experience unlocked.
    case inCircle
}

/// Observable app-wide state for root navigation.
/// Single source of truth for app phase transitions.
@Observable
final class AppState {

    /// Current app phase. Drives RootView branching.
    var phase: AppPhase

    /// ID of the user's currently focused circle (if any).
    /// "Focused" is a UI concept only — determines which circle's
    /// ring and members are displayed. Does NOT imply priority
    /// or exclusivity. User remains a member of all their circles.
    var focusedCircleID: String?

    /// Minimal user info after auth.
    /// Nil until authenticated.
    var currentUserID: String?

    init(phase: AppPhase = .onboarding) {
        self.phase = phase
        self.focusedCircleID = nil
        self.currentUserID = nil
    }

    // MARK: - Phase Transitions
    // Explicit methods for state changes.
    // ViewModels call these; views react.

    /// Called when user completes onboarding.
    /// Transitions to noCircle phase.
    func completeOnboarding() {
        phase = .noCircle
    }

    /// Called when user joins or creates a circle.
    /// Transitions to inCircle phase and focuses the new circle.
    func enterCircle(circleID: String) {
        focusedCircleID = circleID
        phase = .inCircle
    }

    /// Called when user leaves their only circle.
    /// Returns to noCircle phase.
    func leaveCircle() {
        focusedCircleID = nil
        phase = .noCircle
    }

    /// Resets to initial state.
    /// Used for sign-out or testing.
    func reset() {
        phase = .onboarding
        focusedCircleID = nil
        currentUserID = nil
    }
}
