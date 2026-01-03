import SwiftUI

// MARK: - Circle View
// The core social surface. Shows today's group state.
// Creates gentle social pressure through visible completion.
// No feed. No ranking. No performance metrics.

struct CircleView: View {
    // MARK: - Callbacks

    /// Called when user taps "Post Today's Fit".
    /// TODO: Wire to PostView presentation.
    var onPostTap: () -> Void = {}

    /// Called when user taps "View Archive".
    /// TODO: Wire to ArchiveView navigation.
    var onArchiveTap: () -> Void = {}

    /// Called when user taps circle info/settings.
    /// TODO: Wire to CircleSettingsView navigation.
    var onSettingsTap: () -> Void = {}

    // MARK: - Placeholder State
    // TODO: Replace with real data from ViewModel.

    private let circleName = "Daily Fits"
    private let members = Member.placeholders
    private let currentUserID = "user-1"

    // MARK: - Computed State

    private var postedCount: Int {
        members.filter(\.hasPostedToday).count
    }

    private var totalCount: Int {
        members.count
    }

    private var waitingCount: Int {
        totalCount - postedCount
    }

    private var currentUserHasPosted: Bool {
        members.first { $0.id == currentUserID }?.hasPostedToday ?? false
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 32)

                ringSection

                Spacer()
                    .frame(height: 32)

                statusSection

                Spacer()
                    .frame(height: 40)

                membersSection

                Spacer()
                    .frame(height: 48)

                actionsSection

                Spacer()
                    .frame(height: 32)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle(circleName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: onSettingsTap) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(FittedColors.textSecondary)
                }
            }
        }
    }

    // MARK: - Ring Section
    // Circular completion indicator. One segment per member.
    // Filled = posted. Muted = waiting. No glow, no gradients.

    private var ringSection: some View {
        CompletionRing(
            totalSegments: totalCount,
            filledSegments: postedCount
        )
        .frame(width: 180, height: 180)
    }

    // MARK: - Status Section
    // Text nudges. Observational, not commanding.
    // Creates awareness without urgency.

    private var statusSection: some View {
        VStack(spacing: 8) {
            // Primary status
            Text(statusText)
                .font(FittedTypography.body)
                .foregroundStyle(FittedColors.textPrimary)

            // Time-based nudge (contextual)
            if shouldShowTimeNudge {
                Text(timeNudgeText)
                    .font(FittedTypography.caption)
                    .foregroundStyle(FittedColors.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var statusText: String {
        if postedCount == totalCount {
            return "Everyone posted today"
        } else if waitingCount == 1 {
            return "\(postedCount)/\(totalCount) posted · Waiting on 1"
        } else {
            return "\(postedCount)/\(totalCount) posted today"
        }
    }

    private var shouldShowTimeNudge: Bool {
        // TODO: Base on actual time of day.
        // Show after noon if user hasn't posted.
        !currentUserHasPosted && postedCount > 0
    }

    private var timeNudgeText: String {
        // Observational, not pressuring.
        "Most friends have posted by now"
    }

    // MARK: - Members Section
    // Grid of member avatars. Posted = filled. Not posted = muted.
    // No ranking, no ordering by status.

    private var membersSection: some View {
        VStack(spacing: 16) {
            Text("Today")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 20
            ) {
                ForEach(members) { member in
                    MemberCell(
                        member: member,
                        isCurrentUser: member.id == currentUserID
                    )
                }
            }
        }
    }

    // MARK: - Actions Section
    // Primary: Post. Secondary: Archive.
    // Calm, system-native buttons.

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Primary action: Post
            if !currentUserHasPosted {
                Button(action: onPostTap) {
                    Text("Post today's fit")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(FittedColors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                // Already posted: show confirmation
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(FittedColors.accent)

                    Text("Posted today")
                        .font(FittedTypography.body)
                        .foregroundStyle(FittedColors.textSecondary)
                }
                .frame(height: 50)
            }

            // Secondary action: Archive
            Button(action: onArchiveTap) {
                Text("View your fits")
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.textSecondary)
            }
        }
    }
}

// MARK: - Completion Ring
// Segmented circular indicator.
// Matte appearance. No glow. No gradients.
// Incomplete feels unfinished, not failed.

struct CompletionRing: View {
    let totalSegments: Int
    let filledSegments: Int

    /// Gap between segments in degrees.
    private let segmentGap: Double = 4

    /// Stroke width for ring segments.
    private let strokeWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                // Draw each segment
                ForEach(0..<totalSegments, id: \.self) { index in
                    RingSegment(
                        index: index,
                        total: totalSegments,
                        isFilled: index < filledSegments,
                        gapDegrees: segmentGap,
                        strokeWidth: strokeWidth
                    )
                }

                // Center content
                VStack(spacing: 4) {
                    Text("\(filledSegments)")
                        .font(.system(size: 36, weight: .medium, design: .default))
                        .foregroundStyle(FittedColors.textPrimary)

                    Text("of \(totalSegments)")
                        .font(FittedTypography.caption)
                        .foregroundStyle(FittedColors.textTertiary)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Ring Segment
// Individual arc segment of the completion ring.

struct RingSegment: View {
    let index: Int
    let total: Int
    let isFilled: Bool
    let gapDegrees: Double
    let strokeWidth: CGFloat

    private var startAngle: Angle {
        let segmentSize = 360.0 / Double(total)
        let start = segmentSize * Double(index) - 90 // Start from top
        return .degrees(start + gapDegrees / 2)
    }

    private var endAngle: Angle {
        let segmentSize = 360.0 / Double(total)
        let end = segmentSize * Double(index + 1) - 90
        return .degrees(end - gapDegrees / 2)
    }

    var body: some View {
        Circle()
            .trim(from: trimStart, to: trimEnd)
            .stroke(
                isFilled ? FittedColors.accent : FittedColors.fillInactive,
                style: StrokeStyle(
                    lineWidth: strokeWidth,
                    lineCap: .round
                )
            )
            .rotationEffect(.degrees(-90))
    }

    private var trimStart: CGFloat {
        let segmentSize = 1.0 / Double(total)
        let gapFraction = (gapDegrees / 360.0) / 2
        return CGFloat(segmentSize * Double(index) + gapFraction)
    }

    private var trimEnd: CGFloat {
        let segmentSize = 1.0 / Double(total)
        let gapFraction = (gapDegrees / 360.0) / 2
        return CGFloat(segmentSize * Double(index + 1) - gapFraction)
    }
}

// MARK: - Member Cell
// Single member avatar with posted/waiting state.
// No shaming visual treatment for those who haven't posted.

struct MemberCell: View {
    let member: Member
    let isCurrentUser: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Avatar
            ZStack {
                Circle()
                    .fill(member.hasPostedToday
                        ? FittedColors.accent
                        : FittedColors.fillInactive)
                    .frame(width: 56, height: 56)

                Text(member.initial)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(member.hasPostedToday
                        ? FittedColors.backgroundPrimary
                        : FittedColors.textTertiary)
            }

            // Name
            Text(displayName)
                .font(FittedTypography.caption)
                .foregroundStyle(member.hasPostedToday
                    ? FittedColors.textPrimary
                    : FittedColors.textTertiary)
                .lineLimit(1)
        }
    }

    private var displayName: String {
        isCurrentUser ? "You" : member.displayName
    }
}

// MARK: - Member Model
// Placeholder model for circle members.
// TODO: Replace with real model from data layer.

struct Member: Identifiable {
    let id: String
    let displayName: String
    let hasPostedToday: Bool

    var initial: String {
        String(displayName.prefix(1)).uppercased()
    }

    // MARK: - Placeholder Data

    static let placeholders: [Member] = [
        Member(id: "user-1", displayName: "You", hasPostedToday: false),
        Member(id: "user-2", displayName: "Alex", hasPostedToday: true),
        Member(id: "user-3", displayName: "Jordan", hasPostedToday: true),
        Member(id: "user-4", displayName: "Sam", hasPostedToday: true),
        Member(id: "user-5", displayName: "Riley", hasPostedToday: false)
    ]
}

// MARK: - Preview

#Preview("Not Posted Yet") {
    NavigationStack {
        CircleView()
    }
}

#Preview("Already Posted") {
    NavigationStack {
        CircleView()
    }
}
