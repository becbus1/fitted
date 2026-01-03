import SwiftUI

// MARK: - Root View
// Top-level view that switches based on AppState.phase.
// Enforces: onboarding → create/join → circle-home flow.
// No tabs. No browsing. Navigation is phase-gated.

struct RootView: View {
    @Bindable var appState: AppState

    var body: some View {
        // Phase-based branching at root level.
        // Each phase gets its own navigation container.
        switch appState.phase {
        case .onboarding:
            OnboardingContainer(appState: appState)

        case .noCircle:
            // User completed onboarding previously but has no circle.
            // (e.g., left their last circle)
            // Re-uses the same create/join flow.
            CircleSetupContainer(appState: appState)

        case .inCircle:
            CircleHomeContainer(appState: appState)
        }
    }
}

// MARK: - Onboarding Route

/// Navigation destinations within onboarding phase.
enum OnboardingRoute: Hashable {
    case createCircle
    case joinCircle
}

// MARK: - Onboarding Container
// First-time user experience.
// Shows OnboardingIntroView, then navigates to create/join.

struct OnboardingContainer: View {
    @Bindable var appState: AppState
    @State private var path: [OnboardingRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingIntroView(
                onCreateCircle: {
                    path.append(.createCircle)
                },
                onJoinCircle: {
                    path.append(.joinCircle)
                }
            )
            .navigationBarHidden(true)
            .navigationDestination(for: OnboardingRoute.self) { route in
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

// MARK: - Circle Setup Route

/// Navigation destinations for users returning to create/join.
/// (Users who previously onboarded but have no circle)
enum CircleSetupRoute: Hashable {
    case createCircle
    case joinCircle
}

// MARK: - Circle Setup Container
// For returning users who left their circle.
// Shows create/join without philosophy intro.

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

// MARK: - Circle Route

/// Navigation destinations within the main circle experience.
enum CircleRoute: Hashable {
    case archive
    case settings
}

// MARK: - Circle Home Container
// Main app experience after joining a circle.

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
// Structural scaffolding. Features not yet implemented.
// TODO: Replace with actual feature views.

/// Placeholder for returning users without a circle.
/// Shows create/join options without onboarding philosophy.
struct CircleSetupRootPlaceholder: View {
    @Bindable var appState: AppState
    @Binding var path: [CircleSetupRoute]

    var body: some View {
        VStack(spacing: 24) {
            Text("Join or Create a Circle")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("You're not in a circle yet.")
                .font(FittedTypography.body)
                .foregroundStyle(FittedColors.textSecondary)

            VStack(spacing: 12) {
                Button(action: { path.append(.createCircle) }) {
                    Text("Create a Circle")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FittedColors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button(action: { path.append(.joinCircle) }) {
                    Text("Join a Circle")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FittedColors.backgroundSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(FittedColors.separator, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
    }
}

/// Placeholder for circle creation flow.
/// TODO: Implement actual CreateCircleView.
struct CreateCirclePlaceholder: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Create a Circle")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("Circle creation flow")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            // TODO: Replace with actual circle creation logic
            Button(action: {
                appState.enterCircle(circleID: "placeholder-circle-id")
            }) {
                Text("Create & Continue")
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(FittedColors.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Create Circle")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder for circle join flow.
/// TODO: Implement actual JoinCircleView.
struct JoinCirclePlaceholder: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Text("Join a Circle")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("Enter invite code or link")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            // TODO: Replace with actual join logic
            Button(action: {
                appState.enterCircle(circleID: "placeholder-circle-id")
            }) {
                Text("Join & Continue")
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(FittedColors.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Join Circle")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder for circle home (ring + members).
/// TODO: Implement actual CircleView.
struct CircleHomePlaceholder: View {
    @Bindable var appState: AppState
    @Binding var path: [CircleRoute]
    @Binding var isPostPresented: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("Today")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("Circle ring + member status")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)

            VStack(spacing: 12) {
                // TODO: Wire to PostView
                Button(action: { isPostPresented = true }) {
                    Text("Post Today's Fit")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FittedColors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button(action: { path.append(.archive) }) {
                    Text("View Archive")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.textPrimary)
                }

                // Debug only
                Button(action: { appState.leaveCircle() }) {
                    Text("Leave Circle")
                        .font(FittedTypography.caption)
                        .foregroundStyle(FittedColors.textTertiary)
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder for post capture flow.
/// TODO: Implement actual PostView with camera.
struct PostPlaceholder: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Today's Fit")
                    .font(FittedTypography.primary)
                    .foregroundStyle(FittedColors.textPrimary)

                Text("Camera capture placeholder")
                    .font(FittedTypography.caption)
                    .foregroundStyle(FittedColors.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FittedColors.backgroundPrimary)
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
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

/// Placeholder for personal archive.
/// TODO: Implement actual ArchiveView.
struct ArchivePlaceholder: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Your Fits")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("Personal archive placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Placeholder for settings.
/// TODO: Implement actual SettingsView.
struct SettingsPlaceholder: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Settings")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)

            Text("Circle settings placeholder")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Previews

#Preview("Onboarding") {
    RootView(appState: AppState(phase: .onboarding))
}

#Preview("No Circle") {
    RootView(appState: AppState(phase: .noCircle))
}

#Preview("In Circle") {
    let state = AppState(phase: .inCircle)
    state.activeCircleID = "preview-circle"
    return RootView(appState: state)
}
