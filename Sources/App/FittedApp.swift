import SwiftUI

// MARK: - App Entry Point
// Fitted: A daily social ritual app for small groups.
// This is the @main entry point. Initializes AppState
// and injects it into the view hierarchy.

@main
struct FittedApp: App {
    /// App-wide state container.
    /// Owns navigation phase, active circle, user session.
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .environment(appState)
        }
    }
}

// MARK: - Design Notes
//
// Architecture decisions:
//
// 1. Single AppState at root:
//    - Avoids prop drilling for phase changes
//    - Accessible via @Environment where needed
//    - ViewModels can be injected with reference
//
// 2. No TabView:
//    - App is phase-gated, not feature-browsable
//    - Enforces onboarding → circle-setup → circle flow
//    - Prevents "skip to content" patterns
//
// 3. @Observable over ObservableObject:
//    - iOS 17+ modern observation
//    - Finer-grained view updates
//    - Cleaner syntax with @Bindable
//
// 4. Phase-based root switching:
//    - Each phase owns its NavigationStack
//    - Impossible to navigate to invalid states
//    - Clear mental model for developers
//
// Future considerations:
// - Deep link handling in onOpenURL
// - Scene phase observation for background/foreground
// - Persistence of phase across app launches
