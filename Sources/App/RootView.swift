import SwiftUI

// MARK: - Root View
// Top-level view that switches based on AppState.phase.
// Enforces the onboarding → circle-setup → circle-home flow.
// No tab bar. Navigation is phase-gated, not browsable.

struct RootView: View {
    @Bindable var appState: AppState

    var body: some View {
        // Phase-based branching at root level.
        // Each phase gets its own navigation container.
        switch appState.phase {
        case .onboarding:
            OnboardingContainer(appState: appState)

        case .noCircle:
            CircleSetupContainer(appState: appState)

        case .inCircle:
            CircleHomeContainer(appState: appState)
        }
    }
}

// MARK: - Phase Containers
// Each container owns its navigation stack.
// Placeholder views used until features are implemented.

/// Container for onboarding phase.
/// Shows philosophy, routes to create/join.
struct OnboardingContainer: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationStack {
            OnboardingPlaceholder(appState: appState)
        }
    }
}

/// Container for circle setup phase.
/// User has completed onboarding but has no circle.
struct CircleSetupContainer: View {
    @Bindable var appState: AppState
    @State private var path: [CircleSetupRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            CircleSetupRootPlaceholder(appState: appState, path: $path)
                .navigationDestination(for: CircleSetupRoute.self) { route in
                    switch route {
                    case .createCircle:
                        CreateCirclePlaceholder(appState: appState)
                    case .joinCircle:
                        JoinCirclePlaceholder(appState: appState)
                    }
                }
        }
    }
}

/// Container for main circle experience.
/// User belongs to a circle; full app unlocked.
struct CircleHomeContainer: View {
    @Bindable var appState: AppState
    @State private var path: [CircleRoute] = []
    @State private var isPostPresented = false

    var body: some View {
        NavigationStack(path: $path) {
            CircleHomePlaceholder(
                appState: appState,
                path: $path,
                isPostPresented: $isPostPresented
            )
            .navigationDestination(for: CircleRoute.self) { route in
                switch route {
                case .home:
                    CircleHomePlaceholder(
                        appState: appState,
                        path: $path,
                        isPostPresented: $isPostPresented
                    )
                case .post:
                    // Post is modal, handled via sheet.
                    EmptyView()
                case .archive:
                    ArchivePlaceholder()
                case .settings:
                    SettingsPlaceholder()
                }
            }
            .sheet(isPresented: $isPostPresented) {
                PostPlaceholder(isPresented: $isPostPresented)
            }
        }
    }
}

// MARK: - Placeholder Views
// Structural scaffolding only. No UI implementation.
// Each placeholder shows its purpose and provides navigation hooks.

struct OnboardingPlaceholder: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Onboarding")
                .font(FittedTypography.primary)

            Text("Philosophy screen placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            Button("Complete Onboarding") {
                appState.completeOnboarding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
    }
}

struct CircleSetupRootPlaceholder: View {
    @Bindable var appState: AppState
    @Binding var path: [CircleSetupRoute]

    var body: some View {
        VStack(spacing: 24) {
            Text("Create or Join")
                .font(FittedTypography.primary)

            Text("No circle yet. Choose an option.")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            VStack(spacing: 12) {
                Button("Create a Circle") {
                    path.append(.createCircle)
                }

                Button("Join a Circle") {
                    path.append(.joinCircle)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
    }
}

struct CreateCirclePlaceholder: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Create Circle")
                .font(FittedTypography.primary)

            Text("Circle creation flow placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            Button("Create & Enter Circle") {
                appState.enterCircle(circleID: "placeholder-circle-id")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Create Circle")
    }
}

struct JoinCirclePlaceholder: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Join Circle")
                .font(FittedTypography.primary)

            Text("Join via code/link placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            Button("Join & Enter Circle") {
                appState.enterCircle(circleID: "placeholder-circle-id")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Join Circle")
    }
}

struct CircleHomePlaceholder: View {
    @Bindable var appState: AppState
    @Binding var path: [CircleRoute]
    @Binding var isPostPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("Circle Home")
                .font(FittedTypography.primary)

            Text("Ring + member status placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            VStack(spacing: 12) {
                Button("Post Today's Fit") {
                    isPostPresented = true
                }

                Button("View Archive") {
                    path.append(.archive)
                }

                Button("Leave Circle (Debug)") {
                    appState.leaveCircle()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Today")
    }
}

struct PostPlaceholder: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Post")
                    .font(FittedTypography.primary)

                Text("Camera capture placeholder")
                    .font(FittedTypography.caption)
                    .foregroundStyle(FittedColors.textTertiary)

                Button("Dismiss") {
                    isPresented = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FittedColors.backgroundPrimary)
            .navigationTitle("Today's Fit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct ArchivePlaceholder: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Archive")
                .font(FittedTypography.primary)

            Text("Personal closet placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Your Fits")
    }
}

struct SettingsPlaceholder: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Settings")
                .font(FittedTypography.primary)

            Text("Circle settings placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Settings")
    }
}

// MARK: - Preview

#Preview {
    RootView(appState: AppState(phase: .onboarding))
}
