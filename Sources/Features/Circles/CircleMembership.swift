import Foundation
import SwiftUI

// MARK: - Circle Membership Logic
//
// This file defines how users relate to circles in Fitted.
// Membership is the foundation of the social contract.
//
// Core principles:
// - Belonging is the value, not content
// - Leaving is allowed but consequential
// - Rejoining is possible but doesn't erase absence
// - Multiple circles are allowed but one is "active" at a time

// MARK: - Circle Model

/// A private group for daily outfit sharing.
/// Circles are the atomic social unit — no public feeds, no discovery.
struct Circle: Identifiable, Equatable {
    let id: String
    let name: String
    let createdAt: Date
    let createdByUserID: String

    /// Current members of this circle.
    /// TODO: This will be fetched from server, not stored here.
    var memberCount: Int

    /// Invite code for manual entry (fallback).
    /// 6-character alphanumeric, case-insensitive.
    let inviteCode: String

    /// Secure invite link for sharing.
    /// Primary join mechanism via iMessage.
    var inviteURL: URL {
        // TODO: Replace with actual deep link domain
        URL(string: "https://fitted.app/join/\(id)")!
    }
}

// MARK: - Membership Model

/// A user's relationship to a single circle.
/// Tracks join/leave history for integrity.
struct CircleMembership: Identifiable, Equatable {
    let id: String
    let userID: String
    let circleID: String

    /// When the user joined (or rejoined) this circle.
    let joinedAt: Date

    /// If the user has left, when they left.
    /// Nil means currently a member.
    let leftAt: Date?

    /// Whether this membership is currently active.
    var isActive: Bool {
        leftAt == nil
    }

    /// Number of times this user has joined this circle.
    /// Tracked for psychological research, not displayed.
    let joinCount: Int
}

// MARK: - Membership State

/// The user's current membership status in a specific circle.
enum MembershipStatus: Equatable {
    /// User has never been in this circle.
    case notMember

    /// User is currently a member.
    case member(since: Date)

    /// User was a member but left.
    /// They can rejoin, but their absence is recorded.
    case formerMember(leftAt: Date)

    /// Join request is in progress.
    case joining

    /// Leave request is in progress.
    case leaving
}

// MARK: - Multi-Circle State

/// Manages the user's relationship to all their circles.
///
/// Invariants:
/// 1. User can belong to multiple circles simultaneously
/// 2. Exactly one circle is "active" at any time (for UI focus)
/// 3. Posting eligibility is independent per circle
/// 4. Switching circles is instant and free
@Observable
final class CircleMembershipViewModel {

    // MARK: - State

    /// All circles the user currently belongs to.
    private(set) var circles: [Circle] = []

    /// The currently active/focused circle.
    /// CircleView shows this circle's state.
    private(set) var activeCircle: Circle?

    /// Membership status per circle (keyed by circle ID).
    private(set) var membershipStatus: [String: MembershipStatus] = [:]

    /// Current user ID.
    let userID: String

    // MARK: - Initialization

    init(userID: String) {
        self.userID = userID
        // TODO: Load circles from local cache, then sync with server
    }

    // MARK: - Computed Properties

    /// Whether the user belongs to at least one circle.
    var hasAnyCircle: Bool {
        !circles.isEmpty
    }

    /// Number of circles the user belongs to.
    var circleCount: Int {
        circles.count
    }

    /// Whether the user can switch to another circle.
    var canSwitchCircles: Bool {
        circles.count > 1
    }

    // MARK: - Circle Switching

    /// Switch the active circle.
    ///
    /// Psychological note:
    /// Switching is free and instant. We don't want users to feel
    /// "stuck" in a circle. But the active circle is where social
    /// pressure applies — you can't avoid it by switching away.
    func switchToCircle(_ circle: Circle) {
        guard circles.contains(where: { $0.id == circle.id }) else {
            return
        }
        activeCircle = circle

        // TODO: Persist active circle preference locally
    }

    /// Switch to next circle in rotation.
    /// Used for quick switching UI.
    func switchToNextCircle() {
        guard let current = activeCircle,
              let currentIndex = circles.firstIndex(where: { $0.id == current.id }),
              circles.count > 1 else {
            return
        }

        let nextIndex = (currentIndex + 1) % circles.count
        activeCircle = circles[nextIndex]
    }

    // MARK: - Joining

    /// Attempt to join a circle via invite link.
    ///
    /// Returns: The join operation, or nil if already a member.
    func joinCircle(circleID: String) async throws -> Circle {
        // Check if already a member
        if circles.contains(where: { $0.id == circleID }) {
            // Already a member — just switch to it
            if let circle = circles.first(where: { $0.id == circleID }) {
                switchToCircle(circle)
                return circle
            }
        }

        // Mark as joining
        membershipStatus[circleID] = .joining

        // TODO: Call backend to join circle
        // let membership = try await CircleService.join(circleID: circleID)
        // let circle = try await CircleService.fetchCircle(id: circleID)

        // Placeholder for now
        let circle = Circle(
            id: circleID,
            name: "New Circle",
            createdAt: Date(),
            createdByUserID: "unknown",
            memberCount: 1,
            inviteCode: "XXXXXX"
        )

        // Update local state
        circles.append(circle)
        membershipStatus[circleID] = .member(since: Date())

        // Set as active if it's the first circle
        if activeCircle == nil {
            activeCircle = circle
        }

        return circle
    }

    /// Attempt to join via manual invite code.
    /// Fallback mechanism when link doesn't work.
    func joinCircle(inviteCode: String) async throws -> Circle {
        // Normalize code: uppercase, trim whitespace
        let normalizedCode = inviteCode.uppercased().trimmingCharacters(in: .whitespaces)

        guard normalizedCode.count == 6 else {
            throw JoinError.invalidCode
        }

        // TODO: Resolve code to circle ID via backend
        // let circleID = try await CircleService.resolveInviteCode(normalizedCode)

        // Placeholder
        let circleID = "resolved-\(normalizedCode)"
        return try await joinCircle(circleID: circleID)
    }

    // MARK: - Leaving

    /// Leave a circle.
    ///
    /// IMPORTANT PSYCHOLOGICAL DESIGN:
    /// - Leaving is intentional, not accidental (requires confirmation)
    /// - Leaving does NOT delete your posts or archive
    /// - Leaving does NOT let you "redo" missed days if you rejoin
    /// - Your absence will be visible to remaining members
    ///
    /// Copy should feel calm but clear:
    /// "You can rejoin anytime. Your past fits stay in your archive."
    func leaveCircle(_ circle: Circle) async throws {
        guard circles.contains(where: { $0.id == circle.id }) else {
            return
        }

        // Mark as leaving
        membershipStatus[circle.id] = .leaving

        // TODO: Call backend to leave circle
        // try await CircleService.leave(circleID: circle.id)

        // Update local state
        circles.removeAll { $0.id == circle.id }
        membershipStatus[circle.id] = .formerMember(leftAt: Date())

        // If we left the active circle, switch to another
        if activeCircle?.id == circle.id {
            activeCircle = circles.first
        }
    }

    // MARK: - Rejoining

    /// Rejoin a circle the user previously left.
    ///
    /// IMPORTANT:
    /// - Rejoining is allowed (circles are forgiving)
    /// - But missed days are NOT restored
    /// - The user's absence is part of the record
    /// - This prevents gaming by leaving/rejoining
    func rejoinCircle(circleID: String) async throws -> Circle {
        // Same as joining, but we track that this is a rejoin
        return try await joinCircle(circleID: circleID)
    }

    // MARK: - Server Sync

    /// Sync membership state with server.
    func syncWithServer() async throws {
        // TODO: Fetch user's circles from server
        // let serverCircles = try await CircleService.fetchUserCircles()
        // self.circles = serverCircles
        // self.activeCircle = serverCircles.first
    }
}

// MARK: - Join Errors

enum JoinError: Error, LocalizedError {
    case invalidCode
    case circleNotFound
    case alreadyMember
    case circleFull
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "That code doesn't look right. Check and try again."
        case .circleNotFound:
            return "This circle doesn't exist or the link has expired."
        case .alreadyMember:
            return "You're already in this circle."
        case .circleFull:
            return "This circle is full."
        case .networkError:
            return "Couldn't connect. Check your internet and try again."
        }
    }
}

// MARK: - Create Circle ViewModel

/// Manages the circle creation flow.
///
/// Flow:
/// 1. User taps "Create a Circle"
/// 2. We create the circle immediately (no name required)
/// 3. Show invite link with share sheet (iMessage emphasized)
/// 4. User can optionally name the circle later
///
/// Copy philosophy:
/// - Creation is low-stakes ("You can always start another")
/// - Invitation is social ("Share with people you know")
/// - No urgency ("They'll join when they're ready")
@Observable
final class CreateCircleViewModel {

    // MARK: - State

    enum CreateState: Equatable {
        case idle
        case creating
        case created(Circle)
        case error(String)
    }

    private(set) var state: CreateState = .idle

    /// The created circle, if any.
    var createdCircle: Circle? {
        if case .created(let circle) = state {
            return circle
        }
        return nil
    }

    /// Whether share sheet should be presented.
    var showShareSheet = false

    // MARK: - Actions

    /// Create a new circle.
    ///
    /// We create immediately with a default name.
    /// User can rename later if they want.
    func createCircle() async throws -> Circle {
        state = .creating

        // TODO: Call backend to create circle
        // let circle = try await CircleService.create()

        // Generate placeholder circle
        let circleID = UUID().uuidString
        let inviteCode = generateInviteCode()

        let circle = Circle(
            id: circleID,
            name: "My Circle", // Default name, can be changed
            createdAt: Date(),
            createdByUserID: "current-user", // TODO: Real user ID
            memberCount: 1,
            inviteCode: inviteCode
        )

        state = .created(circle)
        return circle
    }

    /// Generate a 6-character invite code.
    private func generateInviteCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // No I/O/0/1 to avoid confusion
        return String((0..<6).map { _ in characters.randomElement()! })
    }

    /// Present the share sheet for the invite link.
    func shareInviteLink() {
        showShareSheet = true
    }

    /// Reset state for creating another circle.
    func reset() {
        state = .idle
        showShareSheet = false
    }
}

// MARK: - Share Sheet Items

/// Items to share when inviting to a circle.
struct CircleInviteShareItems {
    let circle: Circle

    /// The primary share item: invite URL.
    var items: [Any] {
        [inviteMessage, circle.inviteURL]
    }

    /// The message to accompany the link.
    ///
    /// Copy philosophy:
    /// - Personal, not promotional
    /// - Explains what this is briefly
    /// - No urgency or FOMO
    private var inviteMessage: String {
        """
        Join my Fitted circle — we share one outfit a day.
        """
    }

    /// Activity types to emphasize.
    /// iMessage is primary.
    var preferredActivities: [UIActivity.ActivityType] {
        [.message]
    }

    /// Activity types to exclude.
    /// No social media broadcasting.
    var excludedActivities: [UIActivity.ActivityType] {
        [
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .postToFlickr,
            .postToVimeo,
            .postToTencentWeibo,
            .addToReadingList
        ]
    }
}

// MARK: - Join Circle ViewModel

/// Manages the circle joining flow.
///
/// Two entry points:
/// 1. Deep link (auto-join, preferred)
/// 2. Manual code entry (fallback)
@Observable
final class JoinCircleViewModel {

    // MARK: - State

    enum JoinState: Equatable {
        case idle
        case enteringCode
        case joining
        case joined(Circle)
        case error(String)
    }

    private(set) var state: JoinState = .idle

    /// The code being entered manually.
    var manualCode: String = ""

    /// Whether the manual code is valid format.
    var isCodeValid: Bool {
        manualCode.count == 6
    }

    // MARK: - Actions

    /// Start manual code entry.
    func startManualEntry() {
        state = .enteringCode
        manualCode = ""
    }

    /// Join via the entered code.
    func joinWithCode(membershipVM: CircleMembershipViewModel) async {
        guard isCodeValid else { return }

        state = .joining

        do {
            let circle = try await membershipVM.joinCircle(inviteCode: manualCode)
            state = .joined(circle)
        } catch let error as JoinError {
            state = .error(error.localizedDescription)
        } catch {
            state = .error("Something went wrong. Try again.")
        }
    }

    /// Join via deep link (auto-join).
    /// Called when app opens with invite URL.
    func joinViaDeepLink(
        circleID: String,
        membershipVM: CircleMembershipViewModel
    ) async {
        state = .joining

        do {
            let circle = try await membershipVM.joinCircle(circleID: circleID)
            state = .joined(circle)
        } catch let error as JoinError {
            state = .error(error.localizedDescription)
        } catch {
            state = .error("Couldn't join this circle. The link may have expired.")
        }
    }

    /// Reset state.
    func reset() {
        state = .idle
        manualCode = ""
    }
}

// MARK: - Deep Link Handling

/*

 TODO: Implement deep link handling in App entry point.

 Deep link format: https://fitted.app/join/{circleID}

 Implementation outline:

 @main
 struct FittedApp: App {
     @State var membershipVM = CircleMembershipViewModel(userID: "...")
     @State var joinVM = JoinCircleViewModel()
     @State var pendingDeepLink: URL?

     var body: some Scene {
         WindowGroup {
             RootView(...)
                 .onOpenURL { url in
                     handleDeepLink(url)
                 }
                 .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                     if let url = activity.webpageURL {
                         handleDeepLink(url)
                     }
                 }
         }
     }

     func handleDeepLink(_ url: URL) {
         // Parse URL
         guard url.host == "fitted.app",
               url.pathComponents.count >= 2,
               url.pathComponents[1] == "join" else {
             return
         }

         let circleID = url.pathComponents[2]

         // If user is authenticated, join immediately
         // If not, store pending link and join after auth
         if isAuthenticated {
             Task {
                 await joinVM.joinViaDeepLink(circleID: circleID, membershipVM: membershipVM)
             }
         } else {
             pendingDeepLink = url
             // After auth completes, check pendingDeepLink and join
         }
     }
 }

 */

// MARK: - Deferred Deep Link (Post-Install)

/*

 TODO: Handle deferred deep links for new installs.

 When a user taps an invite link but doesn't have the app:
 1. App Store opens
 2. User installs and opens app
 3. We need to remember the invite link

 Options:
 - Apple's App Clip experience (shows join preview)
 - Clipboard checking (less reliable)
 - Server-side attribution (via IDFA alternative)
 - Branch.io or similar SDK

 For v1, simplest approach:
 - On first launch, show "Have an invite code?" option
 - User can paste code manually
 - Deep links work after app is installed

 */

// MARK: - CircleView Multi-Circle Behavior

/*

 When user has multiple circles, CircleView should:

 1. HEADER:
    - Show active circle name
    - If multiple circles, show switcher (e.g., "Daily Fits" with dropdown)
    - Tap to reveal other circles

 2. RING:
    - Shows only the active circle's state
    - Switching circles changes the ring immediately
    - Each circle has independent completion state

 3. POSTING:
    - Posting is per-circle per-day
    - User can post to multiple circles on the same day
    - "Posted today" only applies to current active circle

 4. SWITCHING UI:
    - Simple horizontal swipe or dropdown
    - Show unposted indicator on circles where user hasn't posted today
    - No notifications/badges (too gamified)

 Example header:

 ┌─────────────────────────────────────────┐
 │  Daily Fits ▼                      ⓘ   │  ← Tap to switch circles
 └─────────────────────────────────────────┘

 When expanded:

 ┌─────────────────────────────────────────┐
 │  Daily Fits           ✓ posted today   │
 │  Work Friends         ○ not posted     │
 │  Family               ✓ posted today   │
 └─────────────────────────────────────────┘

 */

// MARK: - Membership Invariants

/*

 MEMBERSHIP INVARIANTS (MUST NEVER BE VIOLATED):

 1. MULTI-CIRCLE ALLOWED
    - Users can belong to any number of circles
    - No limit enforced (maybe soft limit of 10 later)
    - Each circle is independent

 2. ONE ACTIVE CIRCLE
    - Exactly one circle is "active" for UI purposes
    - Switching is free and instant
    - Active circle determines what ring/members are shown

 3. POSTING IS PER-CIRCLE
    - (user, circle, day) is the posting unit
    - Posting to Circle A doesn't affect Circle B
    - Each circle has its own completion ring

 4. LEAVING IS ALLOWED
    - User can leave any circle at any time
    - Leaving removes them from member list
    - Their past posts remain in their personal archive

 5. REJOINING IS ALLOWED
    - Former members can rejoin via invite link
    - Rejoining does NOT erase their absence
    - Missed days are still missed

 6. ARCHIVES PERSIST
    - Personal archive includes all past posts
    - Leaving a circle doesn't delete archive entries
    - Archive is per-user, not per-circle

 7. INVITE LINKS DON'T EXPIRE (v1)
    - Simplicity over security initially
    - TODO: Add expiration later if abuse occurs

 8. NO KICKING (v1)
    - Circle creators can't remove members
    - Members self-govern by leaving
    - TODO: Consider moderation tools later

 */

// MARK: - Leave Flow Copy

/*

 LEAVE CONFIRMATION DIALOG:

 Title: "Leave [Circle Name]?"

 Body:
 "You can rejoin anytime with an invite link.
  Your past fits stay in your archive."

 Buttons:
 - "Cancel" (primary, keeps user in circle)
 - "Leave" (secondary, destructive styling but not red)

 Copy philosophy:
 - Leaving is allowed, not punished
 - Reassurance that data isn't lost
 - Clear that rejoining is possible
 - No guilt-tripping or "are you sure?" chains

 */

// MARK: - Join Flow Copy

/*

 JOIN VIA LINK (SUCCESS):

 "You're in."
 [Circle name]
 [Member avatars]

 "Your first fit is waiting."
 [Post now] button

 ---

 JOIN VIA CODE (MANUAL ENTRY):

 Title: "Join a Circle"

 Placeholder: "Enter 6-letter code"

 Helper text: "Ask your friend for the invite code."

 Error states:
 - Invalid format: "Codes are 6 letters"
 - Not found: "That code doesn't work. Check and try again."
 - Already member: "You're already in this circle."

 ---

 INVITE SENT (AFTER SHARING):

 "Invite sent."
 "They'll join when they're ready."

 No tracking of who received it.
 No "pending" state.
 No urgency.

 */
