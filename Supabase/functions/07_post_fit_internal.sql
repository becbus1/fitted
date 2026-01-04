-- =============================================================================
-- FITTED: post_fit_internal RPC
-- =============================================================================
--
-- Internal RPC called by the post-fit Edge Function.
-- Creates a daily post after image upload has been confirmed.
--
-- THIS IS NOT CALLED DIRECTLY BY CLIENTS.
-- Clients call the Edge Function, which validates the image upload,
-- then calls this RPC to create the database record.
--
-- INVARIANTS ENFORCED:
-- 1. One post per (user, circle, day) - via DB constraint
-- 2. Deleted posts still block reposting - via non-partial unique index
-- 3. User must be active member of circle
-- 4. Server calculates posted_date from timezone (client cannot manipulate)
--
-- SECURITY MODEL: DEFINER
-- Reason: Called by Edge Function with service role. The Edge Function
--         has already validated the user via JWT. This function validates
--         membership and handles the atomic insert with constraint handling.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION post_fit_internal(
    p_user_id UUID,
    p_circle_id UUID,
    p_timezone TEXT,
    p_image_path TEXT,
    p_image_width INTEGER DEFAULT NULL,
    p_image_height INTEGER DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    circle_id UUID,
    posted_date DATE,
    posted_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_today DATE;
    v_post_id UUID;
    v_posted_at TIMESTAMPTZ := NOW();
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate required inputs
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'user_id is required';
    END IF;

    IF p_circle_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'circle_id is required';
    END IF;

    IF p_image_path IS NULL OR p_image_path = '' THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'image_path is required';
    END IF;

    -- =========================================================================
    -- CALCULATE TODAY IN USER'S TIMEZONE
    -- =========================================================================

    -- The server is authoritative for date calculation.
    -- Client provides timezone, server calculates the date.
    -- This prevents client clock manipulation or timezone spoofing.

    BEGIN
        v_today := (v_posted_at AT TIME ZONE COALESCE(p_timezone, 'UTC'))::DATE;
    EXCEPTION WHEN OTHERS THEN
        -- Invalid timezone, fall back to UTC and log warning
        v_today := (v_posted_at AT TIME ZONE 'UTC')::DATE;
        RAISE WARNING 'Invalid timezone "%", falling back to UTC', p_timezone;
    END;

    -- =========================================================================
    -- VALIDATE MEMBERSHIP
    -- =========================================================================

    -- User must be an active member of the circle to post
    IF NOT EXISTS (
        SELECT 1 FROM circle_memberships
        WHERE user_id = p_user_id
          AND circle_id = p_circle_id
          AND left_at IS NULL
    ) THEN
        RAISE EXCEPTION 'NOT_MEMBER'
            USING HINT = 'User must be a member of the circle to post';
    END IF;

    -- =========================================================================
    -- CHECK ELIGIBILITY (PRE-CHECK)
    -- =========================================================================

    -- This is an optimization to fail fast before attempting insert.
    -- The database constraint is the final authority.
    -- Even if this check passes, the INSERT can still fail due to race conditions.

    IF EXISTS (
        SELECT 1 FROM daily_posts
        WHERE user_id = p_user_id
          AND circle_id = p_circle_id
          AND posted_date = v_today
        -- Note: NO deleted_at filter
        -- Deleted posts still block reposting
    ) THEN
        RAISE EXCEPTION 'ALREADY_POSTED'
            USING HINT = 'User has already posted to this circle today';
    END IF;

    -- =========================================================================
    -- INSERT POST
    -- =========================================================================

    -- The unique constraint idx_one_post_per_day handles race conditions.
    -- If two concurrent requests pass the eligibility check, only one
    -- will succeed. The other will get a unique_violation.

    BEGIN
        INSERT INTO daily_posts (
            user_id,
            circle_id,
            posted_date,
            posted_at,
            posted_timezone,
            image_path,
            image_width,
            image_height
        )
        VALUES (
            p_user_id,
            p_circle_id,
            v_today,
            v_posted_at,
            COALESCE(p_timezone, 'UTC'),
            p_image_path,
            p_image_width,
            p_image_height
        )
        RETURNING daily_posts.id INTO v_post_id;

    EXCEPTION WHEN unique_violation THEN
        -- Race condition: another request beat us
        RAISE EXCEPTION 'ALREADY_POSTED'
            USING HINT = 'User has already posted to this circle today (race condition)';
    END;

    -- =========================================================================
    -- RETURN POST DATA
    -- =========================================================================

    RETURN QUERY
    SELECT
        v_post_id AS id,
        p_circle_id AS circle_id,
        v_today AS posted_date,
        v_posted_at AS posted_at;
END;
$$;

COMMENT ON FUNCTION post_fit_internal IS
'Internal RPC for post creation. Called by Edge Function only.
Enforces: One post per (user, circle, day), membership required.
Server-authoritative: Calculates posted_date from timezone.
Race-safe: Unique constraint handles concurrent requests.';
