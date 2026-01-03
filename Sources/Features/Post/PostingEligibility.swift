import Foundation
import SwiftUI

// MARK: - Posting Eligibility Logic
//
// This file defines the invariant rules for daily posting in Fitted.
// These rules are psychologically intentional and must remain airtight.
//
// Core principle: One post per user per calendar day per circle.
//
// Why this matters:
// - Daily rituals require clear boundaries
// - Ambiguity around "can I post?" creates anxiety
// - The constraint creates the value (scarcity = meaning)

// MARK: - Calendar Day Definition

/// Defines what "today" means for posting eligibility.
///
/// CRITICAL: We use LOCAL calendar day, not UTC.
///
/// Psychological rationale:
/// - Users think in terms of their day, not server time
/// - "Did I post today?" must match their lived experience
/// - A user in Tokyo at 11pm shouldn't see "tomorrow's" post window
///
/// Technical implications:
/// - Server must store post timestamps in UTC
/// - Client converts to local day for display and eligibility
/// - Day boundary is midnight in user's local timezone
struct CalendarDay: Equatable, Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    /// The user's current calendar day in their local timezone.
    static var today: CalendarDay {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return CalendarDay(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    /// Creates a CalendarDay from a UTC timestamp, converted to local time.
    static func from(utcTimestamp: Date) -> CalendarDay {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: utcTimestamp)
        return CalendarDay(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    /// Midnight of this day in the user's local timezone.
    var startOfDay: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)!
    }

    /// Midnight of the next day (end of this day's posting window).
    var endOfDay: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

// MARK: - Posting State

/// The user's posting state for a given calendar day.
///
/// This enum represents the TRUTH about whether posting is allowed.
/// UI must reflect this state, not compute its own.
enum PostingState: Equatable {
    /// User has not posted today. Posting is allowed.
    case canPost

    /// User has already posted today. Posting is locked.
    case alreadyPosted(postID: String, timestamp: Date)

    /// A post is currently being uploaded. UI should be locked.
    /// This prevents double-tap and race conditions.
    case posting(optimisticID: String)

    /// Post failed but can be retried.
    /// We allow retry, but only for the same image/attempt.
    case failed(error: PostingError, canRetry: Bool)
}

enum PostingError: Error, Equatable {
    case networkError
    case serverError
    case unknownError
}

// MARK: - Posting Eligibility

/// Derived properties for UI consumption.
/// These are computed from PostingState, never stored separately.
extension PostingState {

    /// Whether the user can initiate a new post right now.
    var canInitiatePost: Bool {
        switch self {
        case .canPost:
            return true
        case .alreadyPosted, .posting:
            return false
        case .failed(_, let canRetry):
            return canRetry
        }
    }

    /// Whether the user has successfully posted today.
    var hasPostedToday: Bool {
        switch self {
        case .alreadyPosted:
            return true
        case .canPost, .posting, .failed:
            return false
        }
    }

    /// Whether posting UI should show a loading state.
    var isPosting: Bool {
        switch self {
        case .posting:
            return true
        default:
            return false
        }
    }
}

// MARK: - Circle Posting ViewModel

/// Manages posting state for a single circle.
///
/// Invariants this class enforces:
/// 1. At most one post per calendar day per user per circle
/// 2. No concurrent post attempts
/// 3. Optimistic UI that resolves correctly
/// 4. Clean state transitions across midnight
@Observable
final class CirclePostingViewModel {

    // MARK: - State

    /// Current posting state for today.
    private(set) var postingState: PostingState = .canPost

    /// The calendar day we're currently tracking.
    /// When this changes, we must re-evaluate posting eligibility.
    private(set) var currentDay: CalendarDay = .today

    /// Cached post from today, if any.
    private var todaysPost: Post?

    /// Circle this ViewModel manages.
    let circleID: String

    /// Current user ID.
    let userID: String

    // MARK: - Initialization

    init(circleID: String, userID: String) {
        self.circleID = circleID
        self.userID = userID

        // TODO: Load persisted state from local storage
        // This handles the case where app was killed mid-post
        recoverPersistedState()
    }

    // MARK: - Computed Properties

    /// Whether the user can post right now.
    /// UI binds to this for enabling/disabling the post button.
    var canPostToday: Bool {
        // Day must still be current
        guard currentDay == .today else {
            return false
        }
        return postingState.canInitiatePost
    }

    /// Whether the user has completed their daily post.
    var hasPostedToday: Bool {
        guard currentDay == .today else {
            return false
        }
        return postingState.hasPostedToday
    }

    // MARK: - Actions

    /// Called when user initiates a post.
    /// Returns an optimistic ID for tracking, or nil if posting not allowed.
    func beginPost() -> String? {
        // INVARIANT: Cannot start a post if not in canPost state
        guard postingState.canInitiatePost else {
            return nil
        }

        // Generate optimistic ID for this attempt
        let optimisticID = UUID().uuidString

        // Transition to posting state immediately
        // This prevents double-tap race conditions
        postingState = .posting(optimisticID: optimisticID)

        // Persist that we're mid-post (crash recovery)
        // TODO: Write to local storage
        persistPostingAttempt(optimisticID: optimisticID)

        return optimisticID
    }

    /// Called when post upload succeeds.
    func postSucceeded(optimisticID: String, post: Post) {
        // INVARIANT: Only accept success for the current attempt
        guard case .posting(let currentID) = postingState,
              currentID == optimisticID else {
            // Stale callback, ignore
            return
        }

        // Verify the post is for today
        let postDay = CalendarDay.from(utcTimestamp: post.createdAt)
        guard postDay == currentDay else {
            // Post was for a different day (midnight crossing)
            // This is an edge case we handle gracefully
            postingState = .canPost
            return
        }

        // Success: lock posting for the rest of the day
        todaysPost = post
        postingState = .alreadyPosted(postID: post.id, timestamp: post.createdAt)

        // Clear persisted attempt
        clearPersistedAttempt()
    }

    /// Called when post upload fails.
    func postFailed(optimisticID: String, error: PostingError) {
        // INVARIANT: Only accept failure for the current attempt
        guard case .posting(let currentID) = postingState,
              currentID == optimisticID else {
            return
        }

        // Determine if retry is allowed
        let canRetry: Bool
        switch error {
        case .networkError:
            canRetry = true
        case .serverError:
            canRetry = true
        case .unknownError:
            canRetry = false
        }

        postingState = .failed(error: error, canRetry: canRetry)
    }

    /// Called to retry a failed post.
    func retryPost() -> String? {
        guard case .failed(_, true) = postingState else {
            return nil
        }

        // Same logic as beginPost
        let optimisticID = UUID().uuidString
        postingState = .posting(optimisticID: optimisticID)
        persistPostingAttempt(optimisticID: optimisticID)
        return optimisticID
    }

    /// Called to abandon a failed post attempt.
    func abandonPost() {
        guard case .failed = postingState else {
            return
        }

        postingState = .canPost
        clearPersistedAttempt()
    }

    // MARK: - Day Boundary Handling

    /// Must be called when app enters foreground or on a timer.
    /// Handles the case where midnight has passed.
    func checkDayBoundary() {
        let today = CalendarDay.today

        if today != currentDay {
            // Day has changed!
            handleDayChange(newDay: today)
        }
    }

    private func handleDayChange(newDay: CalendarDay) {
        // Save the old day's post to archive if needed
        // (handled by a separate archive system)

        // Reset state for the new day
        currentDay = newDay
        todaysPost = nil

        // Check if we have a post for the new day already
        // (edge case: posted just after midnight on another device)
        // TODO: Query local cache or server

        postingState = .canPost

        // Psychological note:
        // The new day feels like a fresh start.
        // The ring resets. Everyone has another chance.
    }

    // MARK: - Persistence (Crash Recovery)

    private func persistPostingAttempt(optimisticID: String) {
        // TODO: Write to UserDefaults or local DB
        // Key: "pending_post_\(circleID)_\(userID)"
        // Value: { optimisticID, startedAt, imageLocalPath }
        //
        // This ensures that if the app crashes mid-upload,
        // we can recover and either retry or mark as failed.
    }

    private func clearPersistedAttempt() {
        // TODO: Clear from local storage
    }

    private func recoverPersistedState() {
        // TODO: On init, check if there's a persisted posting attempt
        //
        // Cases:
        // 1. Attempt exists, but post succeeded server-side → mark as posted
        // 2. Attempt exists, post not on server → offer retry
        // 3. Attempt exists but for yesterday → clear it
        // 4. No attempt → check if user posted today via cache/server
    }

    // MARK: - Server Sync

    /// Called when receiving updated data from server.
    /// Ensures local state matches server truth.
    func syncWithServerState(posts: [Post]) {
        // Find today's post, if any
        let todaysPosts = posts.filter { CalendarDay.from(utcTimestamp: $0.createdAt) == currentDay }

        if let post = todaysPosts.first {
            // Server says we posted today
            todaysPost = post
            postingState = .alreadyPosted(postID: post.id, timestamp: post.createdAt)
        } else {
            // Server says no post today
            // Only update if we're not mid-post
            if case .posting = postingState {
                // Keep posting state, let upload complete
            } else {
                postingState = .canPost
                todaysPost = nil
            }
        }
    }
}

// MARK: - Post Model (Minimal)

/// Minimal post model for this logic.
struct Post: Identifiable, Equatable {
    let id: String
    let userID: String
    let circleID: String
    let createdAt: Date // UTC timestamp from server
    let imageURL: String?
}

// MARK: - Usage in CircleView

/*

 CircleView binds to CirclePostingViewModel like this:

 struct CircleView: View {
     @State var postingVM: CirclePostingViewModel

     var body: some View {
         // ...

         // Post button visibility
         if postingVM.canPostToday {
             Button("Post today's fit") {
                 // Present PostView
             }
         } else if postingVM.hasPostedToday {
             // Show "Posted today" confirmation
             HStack {
                 Image(systemName: "checkmark.circle.fill")
                 Text("Posted today")
             }
         }

         // ...
     }
 }

 */

// MARK: - Usage in PostView

/*

 PostView uses the ViewModel like this:

 struct PostView: View {
     @Bindable var postingVM: CirclePostingViewModel
     var imageData: Data
     var onComplete: () -> Void

     func submitPost() {
         guard let optimisticID = postingVM.beginPost() else {
             // Posting not allowed, dismiss
             onComplete()
             return
         }

         // Start upload
         Task {
             do {
                 let post = try await uploadPost(imageData: imageData)
                 postingVM.postSucceeded(optimisticID: optimisticID, post: post)
                 onComplete()
             } catch {
                 postingVM.postFailed(optimisticID: optimisticID, error: .networkError)
                 // Show retry UI
             }
         }
     }
 }

 */

// MARK: - Midnight Timer

/*

 App-level timer to handle day boundaries:

 @main
 struct FittedApp: App {
     @State var appState = AppState()

     var body: some Scene {
         WindowGroup {
             RootView(appState: appState)
                 .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                     // Check day boundary when returning to app
                     appState.activeCircleVM?.checkDayBoundary()
                 }
                 .onReceive(midnightTimer) { _ in
                     // Check day boundary at midnight
                     appState.activeCircleVM?.checkDayBoundary()
                 }
         }
     }

     var midnightTimer: some Publisher {
         // Publishes at local midnight
         // Implementation: calculate seconds until midnight, schedule timer
     }
 }

 */

// MARK: - Invariant Summary

/*

 POSTING INVARIANTS (MUST NEVER BE VIOLATED):

 1. ONE POST PER DAY
    - At most one post per (userID, circleID, calendarDay) tuple
    - Server is the source of truth, but client enforces optimistically

 2. NO DOUBLE POSTING
    - Once postingState == .posting, no new posts can begin
    - Optimistic ID ensures we match responses to the correct attempt

 3. NO DELETE-REPOST
    - Posts cannot be deleted in v1
    - If added later, deletion does NOT re-enable posting for that day
    - Psychological: you showed up or you didn't

 4. CLEAN DAY BOUNDARIES
    - Day boundary is midnight local time
    - State resets at midnight (new chance for everyone)
    - Posts made just before midnight count for "yesterday"
    - Posts made just after midnight count for "today"

 5. CRASH RECOVERY
    - If app crashes mid-post, we recover on next launch
    - Check server for success, offer retry if not
    - Never leave user in a broken state

 6. OPTIMISTIC LOCKING
    - Client shows "posted" immediately after upload succeeds
    - Server sync can override if there's a conflict
    - But conflicts should be rare (one user, one device, one post)

 */

// MARK: - Edge Cases

/*

 EDGE CASE 1: App backgrounded mid-post
 - Image upload continues in background (URLSession background task)
 - On return to foreground, check if upload completed
 - If yes, mark as posted; if no, show retry

 EDGE CASE 2: Post succeeds but UI dismiss fails
 - Server has the post, but UI might not know
 - On next CircleView load, sync with server
 - Server truth wins; UI shows "Posted today"

 EDGE CASE 3: User crosses midnight while app is open
 - Midnight timer fires, calls checkDayBoundary()
 - State resets: canPost becomes true again
 - Ring resets: everyone's count goes to 0/N
 - User can post for the new day

 EDGE CASE 4: User posts at 11:59:59 PM
 - Post is timestamped by server (UTC)
 - Server timestamp determines which day it counts for
 - If server receives at 12:00:01 AM, it's tomorrow's post
 - Client must accept server's day assignment

 EDGE CASE 5: Time zone change
 - User travels across time zones
 - "Today" is always LOCAL calendar day
 - A post made at 11 PM in NYC is still "today" if user flies to LA
 - This is acceptable; we prioritize user's lived experience

 EDGE CASE 6: Multiple devices
 - User posts on iPhone, opens iPad
 - iPad syncs with server, sees today's post
 - iPad marks as posted, no double-posting
 - This is why server is source of truth

 */
