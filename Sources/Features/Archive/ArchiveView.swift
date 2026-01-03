import SwiftUI

// MARK: - Archive View
// Personal memory surface. Not a feed, not a gallery.
// Quiet reflection on showing up consistently.
// No metrics. No counts. No celebration.

struct ArchiveView: View {
    // MARK: - State

    @State private var selectedFit: ArchivedFit?

    // MARK: - Placeholder Data
    // TODO: Replace with real data from ViewModel/Repository.

    private let archivedFits = ArchivedFit.placeholders

    // MARK: - Grid Layout
    // Fixed 3 columns. Square cells. No variation.

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    // MARK: - Grouped Data

    private var fitsByMonth: [(month: String, fits: [ArchivedFit])] {
        let grouped = Dictionary(grouping: archivedFits) { $0.monthKey }
        return grouped
            .map { (month: $0.key, fits: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.fits.first?.date ?? .distantPast > $1.fits.first?.date ?? .distantPast }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 32, pinnedViews: []) {
                ForEach(fitsByMonth, id: \.month) { section in
                    monthSection(month: section.month, fits: section.fits)
                }

                // End of archive — finite, bounded
                archiveFooter
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(FittedColors.backgroundPrimary)
        .navigationTitle("Your fits")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedFit) { fit in
            FitDetailView(fit: fit) {
                selectedFit = nil
            }
        }
    }

    // MARK: - Month Section

    private func monthSection(month: String, fits: [ArchivedFit]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Month header — neutral, temporal
            Text(month)
                .font(FittedTypography.body)
                .foregroundStyle(FittedColors.textSecondary)
                .padding(.leading, 4)

            // Grid of fits
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(fits) { fit in
                    ArchiveFitCell(fit: fit)
                        .onTapGesture {
                            selectedFit = fit
                        }
                }
            }
        }
    }

    // MARK: - Archive Footer
    // Signals the archive is finite. Not infinite scroll.

    private var archiveFooter: some View {
        VStack(spacing: 8) {
            Text("That's everything")
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

// MARK: - Archive Fit Cell
// Single grid cell. Square. Photo + date below.
// No shadows. No lift. No decorative treatment.

struct ArchiveFitCell: View {
    let fit: ArchivedFit

    var body: some View {
        VStack(spacing: 6) {
            // Photo placeholder
            // TODO: Replace with AsyncImage loading from CDN.
            Rectangle()
                .fill(fit.placeholderColor)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Date — quiet, neutral
            Text(fit.shortDateLabel)
                .font(FittedTypography.caption)
                .foregroundStyle(FittedColors.textTertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Fit Detail View
// Full-screen view of a single past fit.
// Photo + date. Nothing else. No editing. No sharing.

struct FitDetailView: View {
    let fit: ArchivedFit
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Background
            FittedColors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(FittedColors.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()

                // Photo
                // TODO: Replace with actual image from storage.
                Rectangle()
                    .fill(fit.placeholderColor)
                    .aspectRatio(3/4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 24)

                Spacer()
                    .frame(height: 24)

                // Date — quiet, temporal
                Text(fit.fullDateLabel)
                    .font(FittedTypography.body)
                    .foregroundStyle(FittedColors.textSecondary)

                Spacer()
            }
        }
    }
}

// MARK: - Archived Fit Model
// Placeholder model for past fits.
// TODO: Replace with real model from data layer.

struct ArchivedFit: Identifiable {
    let id: String
    let date: Date
    let imageURL: String? // TODO: Wire to actual CDN URL

    // MARK: - Display Helpers

    var monthKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    var shortDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    var fullDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // Placeholder color for development
    var placeholderColor: Color {
        FittedColors.backgroundSecondary
    }

    // MARK: - Placeholder Data

    static let placeholders: [ArchivedFit] = {
        let calendar = Calendar.current
        let today = Date()

        var fits: [ArchivedFit] = []

        // Generate placeholder fits for past days
        // Simulates ~3 weeks of daily posting with some gaps
        let daysWithPosts = [0, 1, 2, 4, 5, 6, 7, 9, 10, 11, 12, 14, 15, 17, 18, 19, 20, 21]

        for dayOffset in daysWithPosts {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) {
                fits.append(ArchivedFit(
                    id: "fit-\(dayOffset)",
                    date: date,
                    imageURL: nil
                ))
            }
        }

        return fits
    }()
}

// MARK: - Design Notes
//
// This screen is intentionally quiet.
//
// Why no counts:
// - "12 posts this month" creates performance framing
// - We want identity continuity, not achievement tracking
//
// Why no infinite scroll:
// - Bounded scrolling prevents nostalgia-looping
// - "That's everything" signals a natural end
//
// Why square cells:
// - Uniform, calm grid
// - No visual hierarchy between fits
// - Every day matters equally
//
// Why no sharing:
// - v1 is about personal reflection
// - Sharing creates performance pressure
// - May add later with careful constraints
//
// TODO: NEVER add "best of", "highlights", or streak counters.
// This is a memory surface, not a leaderboard.

// MARK: - Preview

#Preview {
    NavigationStack {
        ArchiveView()
    }
}
