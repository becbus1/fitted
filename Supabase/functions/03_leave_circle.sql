-- =============================================================================
-- FITTED: leave_circle RPC
-- =============================================================================
--
-- Removes user from a circle without deleting their posts.
--
-- INVARIANTS ENFORCED:
-- 1. Leaving is idempotent (not member = success)
-- 2. Posts are NOT deleted (remain in archive and circle history)
-- 3. Membership history is preserved (left_at is set, not deleted)
-- 4. User can only leave their own memberships
-- 5. User must be authenticated
--
-- SECURITY MODEL: INVOKER
-- Reason: User is updating their own membership. RLS policy
--         memberships_update_own already permits this. No bypass needed.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION leave_circle(
    p_circle_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_user_id UUID := auth.uid();
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED'
            USING HINT = 'User must be authenticated to leave a circle';
    END IF;

    -- Validate input
    IF p_circle_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'circle_id is required';
    END IF;

    -- =========================================================================
    -- UPDATE MEMBERSHIP
    -- =========================================================================

    -- Set left_at to mark membership as inactive.
    -- RLS policy ensures user can only update their own memberships.
    --
    -- This is idempotent:
    -- - If already left (left_at IS NOT NULL): 0 rows affected
    -- - If never a member: 0 rows affected
    -- - If active member: 1 row affected
    --
    -- All cases return success (no error on 0 rows).

    UPDATE circle_memberships
    SET
        left_at = NOW(),
        updated_at = NOW()
    WHERE user_id = v_user_id
      AND circle_id = p_circle_id
      AND left_at IS NULL;

    -- =========================================================================
    -- IMPORTANT: Posts are NOT affected
    -- =========================================================================
    -- By design, leaving a circle does NOT delete the user's posts.
    -- Posts remain:
    -- - In the user's personal archive
    -- - Visible to remaining circle members (historical record)
    -- - Associated with the circle (circle_id is preserved)
    --
    -- This is enforced by having NO CASCADE on the membership → posts relationship
    -- and by NOT touching the daily_posts table in this function.

END;
$$;

COMMENT ON FUNCTION leave_circle IS
'Removes user from a circle by setting left_at. Idempotent.
Enforces: AUTH_REQUIRED, user can only leave own memberships.
Preserves: Posts remain in archive and circle history.';
