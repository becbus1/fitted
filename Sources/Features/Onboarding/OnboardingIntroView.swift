import SwiftUI

// MARK: - Onboarding Intro View
// The very first screen users see.
// Communicates product philosophy and forces group-first framing.
// No browsing. No exploration. No skip. Just Create or Join.

struct OnboardingIntroView: View {
    // MARK: - Callbacks
    // Placeholder actions for navigation wiring.

    /// Called when user taps "Create a Circle".
    /// TODO: Wire to CreateCircleView navigation.
    var onCreateCircle: () -> Void = {}

    /// Called when user taps "Join a Circle".
    /// TODO: Wire to JoinCircleView navigation.
    var onJoinCircle: () -> Void = {}

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 80)

                philosophySection

                Spacer()
                    .frame(height: 48)

                actionButtons

                Spacer()
                    .frame(height: 56)

                examplePreviewSection

                Spacer()
                    .frame(height: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .scrollIndicators(.hidden)
        .background(FittedColors.backgroundPrimary)
    }

    // MARK: - Philosophy Section
    // Core message. Sets expectations immediately.
    // Text should feel observational, not promotional.

    private var philosophySection: some View {
        VStack(spacing: 20) {
            Text("Fitted works in small groups.")
                .font(FittedTypography.primary)
                .foregroundStyle(FittedColors.textPrimary)
                .multilineTextAlignment(.center)

            Text("Post one outfit a day with people you know.\nNo likes. No feed. No pressure.")
                .font(FittedTypography.body)
                .foregroundStyle(FittedColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Action Buttons
    // Only two options. No escape hatch.
    // Buttons are calm, system-native, low-pressure.

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: onCreateCircle) {
                Text("Create a Circle")
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(FittedColors.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button(action: onJoinCircle) {
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
    }

    // MARK: - Example Preview Section
    // Static, non-interactive, clearly labeled.
    // Shows structure, not content. Reduces confusion without enabling browsing.

    private var examplePreviewSection: some View {
        VStack(spacing: 16) {
            // Label: clearly marks this as illustrative
            Text("Example")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            // Static preview grid
            HStack(spacing: 12) {
                ForEach(examplePreviews) { preview in
                    ExamplePreviewCell(preview: preview)
                }
            }

            // Contextual footnote
            Text("Most circles have 3–7 people")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
    }

    // MARK: - Example Data
    // Hardcoded. Never live. Never real users.

    private var examplePreviews: [ExamplePreview] {
        [
            ExamplePreview(id: 1, initial: "A", dayLabel: "Mon"),
            ExamplePreview(id: 2, initial: "J", dayLabel: "Mon"),
            ExamplePreview(id: 3, initial: "S", dayLabel: "Mon")
        ]
    }
}

// MARK: - Example Preview Model
// Minimal data for static illustration.

private struct ExamplePreview: Identifiable {
    let id: Int
    let initial: String
    let dayLabel: String
}

// MARK: - Example Preview Cell
// A single placeholder "fit" card.
// Abstract, not photographic. Suggests structure only.

private struct ExamplePreviewCell: View {
    let preview: ExamplePreview

    var body: some View {
        VStack(spacing: 8) {
            // Placeholder image area
            // Muted, abstract rectangle. Not a photo.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FittedColors.backgroundSecondary)
                .aspectRatio(3/4, contentMode: .fit)
                .overlay(
                    // Subtle initial indicator
                    Text(preview.initial)
                        .font(FittedTypography.caption)
                        .foregroundStyle(FittedColors.textTertiary)
                )

            // Day label
            Text(preview.dayLabel)
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: 80)
    }
}

// MARK: - Preview

#Preview {
    OnboardingIntroView(
        onCreateCircle: { print("Create tapped") },
        onJoinCircle: { print("Join tapped") }
    )
}
