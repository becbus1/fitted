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
        }
    }
}

// MARK: - Architecture Notes
//
// 1. Single AppState at root:
//    - Passed explicitly to RootView
//    - ViewModels receive reference for mutations
//    - Views observe via @Bindable
//
// 2. No TabView:
//    - App is phase-gated, not feature-browsable
//    - Enforces onboarding → create/join → circle flow
//    - Prevents "skip to content" patterns
//
// 3. @Observable (iOS 17+):
//    - Modern observation system
//    - Finer-grained view updates
//    - Cleaner syntax with @Bindable
//
// 4. Phase-based navigation:
//    - Each phase owns its NavigationStack
//    - Invalid state transitions prevented by design
//
// Future:
// - Deep link handling via onOpenURL
// - Persistence of phase across launches
// - Scene phase observation
