-- =============================================================================
-- FITTED: Supabase PostgreSQL Schema
-- =============================================================================
--
-- This schema enforces the product invariants at the database level.
-- The server is the source of truth. Client state is optimistic only.
--
-- LOCKED PRODUCT RULES:
-- 1. Users can belong to multiple circles simultaneously.
-- 2. One post per (user_id, circle_id, calendar_day).
-- 3. Calendar day = user's local date at time of posting.
-- 4. Deleting a post does NOT allow reposting the same day.
-- 5. Leaving a circle does not delete posts or archives.
-- 6. Rejoining a circle does not restore missed posts.
-- 7. Invite links map securely to circles.
-- 8. Server is the ultimate source of truth.
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- USERS
-- -----------------------------------------------------------------------------
-- Minimal user record. Auth is handled by Supabase Auth.
-- This table stores app-specific user data only.

CREATE TABLE users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Display name shown in circles
    display_name TEXT NOT NULL,

    -- User's preferred timezone (IANA format, e.g., "America/New_York")
    -- Used for calendar day calculations and UI display.
    -- CRITICAL: This determines what "today" means for the user.
    timezone TEXT NOT NULL DEFAULT 'UTC',

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for auth lookups
CREATE INDEX idx_users_created_at ON users(created_at);

COMMENT ON TABLE users IS
'App-specific user data. Auth handled by Supabase Auth.';

COMMENT ON COLUMN users.timezone IS
'IANA timezone for calendar day calculation. "Today" is defined in user local time.';


-- -----------------------------------------------------------------------------
-- CIRCLES
-- -----------------------------------------------------------------------------
-- A private group for daily outfit sharing.
-- Circles are the atomic social unit — no public feeds, no discovery.

CREATE TABLE circles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Circle name (optional, can be renamed)
    name TEXT NOT NULL DEFAULT 'My Circle',

    -- Who created this circle
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,

    -- 6-character invite code for manual entry (fallback mechanism)
    -- Uppercase alphanumeric, excluding ambiguous characters (I/O/0/1)
    -- Unique and indexed for fast lookups.
    invite_code CHAR(6) NOT NULL UNIQUE,

    -- Invite codes don't expire in v1 (simplicity over security)
    -- TODO: Add invite_expires_at if abuse occurs

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Soft delete: circle is hidden but data preserved
    -- Circles are rarely deleted; this protects archive integrity.
    deleted_at TIMESTAMPTZ DEFAULT NULL
);

-- Fast lookup by invite code (primary join mechanism)
CREATE UNIQUE INDEX idx_circles_invite_code ON circles(invite_code)
    WHERE deleted_at IS NULL;

-- Find circles created by a user
CREATE INDEX idx_circles_created_by ON circles(created_by_user_id);

COMMENT ON TABLE circles IS
'Private groups for daily outfit sharing. No public discovery.';

COMMENT ON COLUMN circles.invite_code IS
'6-char code for manual entry. Primary join is via deep link using circle ID.';

COMMENT ON COLUMN circles.deleted_at IS
'Soft delete preserves archive data. Hard delete would orphan posts.';


-- -----------------------------------------------------------------------------
-- CIRCLE MEMBERSHIPS
-- -----------------------------------------------------------------------------
-- Tracks user membership in circles.
-- Users can belong to multiple circles simultaneously.
-- Membership history is preserved for leave/rejoin tracking.
--
-- PSYCHOLOGICAL INTENT:
-- - Leaving is allowed but consequential (absence is recorded)
-- - Rejoining is possible but doesn't erase history
-- - This prevents gaming by leaving/rejoining to avoid accountability

CREATE TABLE circle_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    circle_id UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,

    -- When this membership began
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- When user left (NULL = currently active member)
    -- Setting this does NOT delete posts or archive entries.
    left_at TIMESTAMPTZ DEFAULT NULL,

    -- How many times this user has joined this circle
    -- Tracked for analytics, not displayed to users.
    -- Incremented on each rejoin.
    join_count INTEGER NOT NULL DEFAULT 1,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- INVARIANT: Only one active membership per (user, circle) at a time.
    -- Enforced via unique partial index below.
    -- Historical memberships (left_at IS NOT NULL) are preserved.

    CONSTRAINT valid_membership_dates CHECK (
        left_at IS NULL OR left_at >= joined_at
    )
);

-- CRITICAL: Enforce one active membership per (user, circle)
-- This allows historical records while preventing duplicate active memberships.
CREATE UNIQUE INDEX idx_active_membership
    ON circle_memberships(user_id, circle_id)
    WHERE left_at IS NULL;

-- Find all circles a user belongs to (active only)
CREATE INDEX idx_memberships_user_active
    ON circle_memberships(user_id)
    WHERE left_at IS NULL;

-- Find all members of a circle (active only)
CREATE INDEX idx_memberships_circle_active
    ON circle_memberships(circle_id)
    WHERE left_at IS NULL;

-- Find membership history for a user in a circle
CREATE INDEX idx_memberships_user_circle
    ON circle_memberships(user_id, circle_id, joined_at DESC);

COMMENT ON TABLE circle_memberships IS
'User membership in circles. Supports multiple circles and leave/rejoin history.';

COMMENT ON COLUMN circle_memberships.left_at IS
'NULL = active member. Setting this does NOT delete posts. Absence is recorded.';

COMMENT ON COLUMN circle_memberships.join_count IS
'Incremented on rejoin. Tracks commitment without displaying to shame users.';


-- -----------------------------------------------------------------------------
-- DAILY POSTS
-- -----------------------------------------------------------------------------
-- The core posting table. Enforces one post per (user, circle, calendar_day).
--
-- CRITICAL INVARIANTS:
-- 1. Unique constraint on (user_id, circle_id, posted_date)
-- 2. Soft delete does NOT release the date slot (no reposting after delete)
-- 3. Posts persist even if user leaves circle (archive integrity)
--
-- PSYCHOLOGICAL INTENT:
-- - You get one shot per day. No retakes, no do-overs.
-- - This creates the "daily ritual" constraint that gives the app meaning.
-- - Deletion is allowed but you still "used" that day.

CREATE TABLE daily_posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    circle_id UUID NOT NULL REFERENCES circles(id) ON DELETE CASCADE,

    -- The calendar date this post counts for.
    -- Stored as DATE in the user's local timezone at time of posting.
    -- This is the AUTHORITATIVE day assignment — server decides, not client.
    --
    -- WHY DATE NOT TIMESTAMP:
    -- - The product constraint is "one per day", not "one per 24 hours"
    -- - Storing as DATE makes the constraint simple and correct
    -- - The user's timezone at posting time determines the date
    posted_date DATE NOT NULL,

    -- Actual UTC timestamp of when the post was created
    -- Used for ordering within a day and debugging
    posted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- The timezone used to calculate posted_date
    -- Stored for audit trail and debugging
    -- Format: IANA timezone (e.g., "America/New_York")
    posted_timezone TEXT NOT NULL,

    -- Path to image in Supabase Storage
    -- Format: "posts/{user_id}/{post_id}.jpg"
    -- TODO: Add storage bucket and policies separately
    image_path TEXT NOT NULL,

    -- Image dimensions for layout (optional but useful)
    image_width INTEGER,
    image_height INTEGER,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Soft delete: post is hidden but date slot remains occupied.
    -- CRITICAL: Deleting does NOT allow reposting the same day.
    -- The unique constraint includes deleted posts intentionally.
    deleted_at TIMESTAMPTZ DEFAULT NULL
);

-- =============================================================================
-- THE CRITICAL CONSTRAINT
-- =============================================================================
-- This is the most important constraint in the entire schema.
-- It enforces: ONE POST PER (USER, CIRCLE, CALENDAR DAY).
--
-- NOTE: This is a regular unique constraint, NOT a partial index.
-- Deleted posts still occupy the date slot. This is intentional.
-- You cannot delete a post and then repost the same day.
--
-- PSYCHOLOGICAL REASON:
-- The daily ritual only works if the constraint is real.
-- If you could delete and retry, it becomes "best of N attempts".
-- That undermines the low-pressure, "just show up" philosophy.
-- =============================================================================

CREATE UNIQUE INDEX idx_one_post_per_day
    ON daily_posts(user_id, circle_id, posted_date);

-- Find all posts by a user (for personal archive)
-- Ordered by date descending for chronological display
CREATE INDEX idx_posts_user_date
    ON daily_posts(user_id, posted_date DESC)
    WHERE deleted_at IS NULL;

-- Find all posts in a circle for a specific date (for completion ring)
CREATE INDEX idx_posts_circle_date
    ON daily_posts(circle_id, posted_date)
    WHERE deleted_at IS NULL;

-- Find today's posts in a circle (hot path for CircleView)
CREATE INDEX idx_posts_circle_today
    ON daily_posts(circle_id, posted_date, user_id)
    WHERE deleted_at IS NULL;

COMMENT ON TABLE daily_posts IS
'One outfit post per user per circle per calendar day. Core product constraint.';

COMMENT ON COLUMN daily_posts.posted_date IS
'Calendar date in user local timezone. Unique per (user, circle). Server authoritative.';

COMMENT ON COLUMN daily_posts.posted_timezone IS
'IANA timezone used to calculate posted_date. Audit trail for day boundary edge cases.';

COMMENT ON COLUMN daily_posts.deleted_at IS
'Soft delete hides post but does NOT free the date slot. No same-day reposting.';


-- -----------------------------------------------------------------------------
-- HELPER FUNCTIONS
-- -----------------------------------------------------------------------------

-- Function to check if a user can post to a circle today
-- Returns TRUE if no post exists for (user, circle, today in user timezone)
CREATE OR REPLACE FUNCTION can_post_today(
    p_user_id UUID,
    p_circle_id UUID,
    p_user_timezone TEXT DEFAULT 'UTC'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_today DATE;
    v_exists BOOLEAN;
BEGIN
    -- Calculate "today" in user's timezone
    v_today := (NOW() AT TIME ZONE p_user_timezone)::DATE;

    -- Check if post exists (including deleted posts!)
    SELECT EXISTS(
        SELECT 1 FROM daily_posts
        WHERE user_id = p_user_id
          AND circle_id = p_circle_id
          AND posted_date = v_today
    ) INTO v_exists;

    RETURN NOT v_exists;
END;
$$;

COMMENT ON FUNCTION can_post_today IS
'Check posting eligibility. Returns FALSE even if previous post was deleted.';


-- Function to get circle completion status for today
-- Returns count of members who have posted today
CREATE OR REPLACE FUNCTION get_circle_completion(
    p_circle_id UUID,
    p_reference_timezone TEXT DEFAULT 'UTC'
)
RETURNS TABLE(
    total_members BIGINT,
    posted_today BIGINT,
    member_statuses JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_today DATE;
BEGIN
    v_today := (NOW() AT TIME ZONE p_reference_timezone)::DATE;

    RETURN QUERY
    SELECT
        COUNT(DISTINCT cm.user_id) AS total_members,
        COUNT(DISTINCT dp.user_id) AS posted_today,
        jsonb_agg(
            jsonb_build_object(
                'user_id', cm.user_id,
                'display_name', u.display_name,
                'has_posted', dp.id IS NOT NULL
            )
        ) AS member_statuses
    FROM circle_memberships cm
    JOIN users u ON u.id = cm.user_id
    LEFT JOIN daily_posts dp ON dp.user_id = cm.user_id
        AND dp.circle_id = cm.circle_id
        AND dp.posted_date = v_today
        AND dp.deleted_at IS NULL
    WHERE cm.circle_id = p_circle_id
      AND cm.left_at IS NULL;
END;
$$;

COMMENT ON FUNCTION get_circle_completion IS
'Get circle posting status for today. Used by CircleView completion ring.';


-- -----------------------------------------------------------------------------
-- ROW LEVEL SECURITY (RLS) POLICIES
-- -----------------------------------------------------------------------------
-- Supabase uses RLS to control data access.
-- These policies enforce that users can only access their own data
-- and data from circles they belong to.

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE circles ENABLE ROW LEVEL SECURITY;
ALTER TABLE circle_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_posts ENABLE ROW LEVEL SECURITY;

-- Users: can read/update own profile only
CREATE POLICY users_select_own ON users
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY users_update_own ON users
    FOR UPDATE USING (auth.uid() = id);

-- Circles: can read circles you're a member of
CREATE POLICY circles_select_member ON circles
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM circle_memberships
            WHERE circle_id = circles.id
              AND user_id = auth.uid()
              AND left_at IS NULL
        )
        OR created_by_user_id = auth.uid()
    );

-- Circles: anyone can read by invite code (for joining)
CREATE POLICY circles_select_by_invite ON circles
    FOR SELECT USING (TRUE);
    -- Note: Limit fields returned in actual queries, not policy

-- Circles: only creator can update
CREATE POLICY circles_update_creator ON circles
    FOR UPDATE USING (created_by_user_id = auth.uid());

-- Circles: authenticated users can create
CREATE POLICY circles_insert_auth ON circles
    FOR INSERT WITH CHECK (auth.uid() = created_by_user_id);

-- Memberships: can read memberships for circles you're in
CREATE POLICY memberships_select_circle ON circle_memberships
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM circle_memberships cm2
            WHERE cm2.circle_id = circle_memberships.circle_id
              AND cm2.user_id = auth.uid()
              AND cm2.left_at IS NULL
        )
    );

-- Memberships: can insert own membership (joining)
CREATE POLICY memberships_insert_own ON circle_memberships
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- Memberships: can update own membership (leaving)
CREATE POLICY memberships_update_own ON circle_memberships
    FOR UPDATE USING (user_id = auth.uid());

-- Posts: can read posts from circles you're in (or your own for archive)
CREATE POLICY posts_select ON daily_posts
    FOR SELECT USING (
        user_id = auth.uid()  -- Own posts (archive)
        OR EXISTS (
            SELECT 1 FROM circle_memberships
            WHERE circle_id = daily_posts.circle_id
              AND user_id = auth.uid()
              AND left_at IS NULL
        )
    );

-- Posts: can insert own posts
CREATE POLICY posts_insert_own ON daily_posts
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- Posts: can soft-delete own posts
CREATE POLICY posts_update_own ON daily_posts
    FOR UPDATE USING (user_id = auth.uid());

-- Posts: no hard deletes allowed
-- (Soft delete via UPDATE to set deleted_at)


-- -----------------------------------------------------------------------------
-- UPDATED_AT TRIGGER
-- -----------------------------------------------------------------------------
-- Automatically update updated_at on row changes

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER circles_updated_at
    BEFORE UPDATE ON circles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER memberships_updated_at
    BEFORE UPDATE ON circle_memberships
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER posts_updated_at
    BEFORE UPDATE ON daily_posts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- =============================================================================
-- SCHEMA SUMMARY
-- =============================================================================
--
-- Tables:
--   users              - App-specific user data (display name, timezone)
--   circles            - Private groups with invite codes
--   circle_memberships - Many-to-many with leave/rejoin history
--   daily_posts        - One post per (user, circle, day) - CORE CONSTRAINT
--
-- Key Constraints:
--   1. idx_one_post_per_day - Enforces daily ritual at DB level
--   2. idx_active_membership - One active membership per (user, circle)
--   3. Soft deletes preserve date slots (no repost after delete)
--
-- Timezone Handling:
--   - User's timezone stored in users.timezone
--   - posted_date calculated server-side using user's timezone
--   - posted_timezone stored for audit trail
--   - "Today" is always user's local calendar day
--
-- Why This Works:
--   - Server is authoritative (client is optimistic only)
--   - Constraints are enforced at DB level, not just app level
--   - Soft deletes preserve data integrity
--   - History is preserved for leave/rejoin (no gaming)
--
-- =============================================================================
