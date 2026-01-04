-- =============================================================================
-- FITTED: delete_post RPC
-- =============================================================================
--
-- Soft-deletes a post without freeing the date slot.
--
-- INVARIANTS ENFORCED:
-- 1. Deletion is idempotent (already deleted = success)
-- 2. Post is hidden but slot remains occupied
-- 3. User cannot repost the same day after deletion
-- 4. User can only delete their own posts (via RLS)
-- 5. User must be authenticated
--
-- WHAT THIS DOES NOT DO:
-- - Does NOT free the date slot for reposting
-- - Does NOT remove the post from completion ring calculation
-- - Does NOT affect other users' view of completion status
-- - Does NOT delete the image from storage
--
-- SECURITY MODEL: INVOKER
-- Reason: User is updating their own post. RLS policy posts_update_own
--         permits this. No bypass needed.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION delete_post(
    p_post_id UUID
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
            USING HINT = 'User must be authenticated to delete a post';
    END IF;

    -- Validate input
    IF p_post_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'post_id is required';
    END IF;

    -- =========================================================================
    -- SOFT DELETE
    -- =========================================================================

    -- Set deleted_at to hide the post.
    -- RLS policy ensures user can only update their own posts.
    --
    -- This is idempotent:
    -- - If already deleted (deleted_at IS NOT NULL): 0 rows affected
    -- - If post doesn't exist: 0 rows affected
    -- - If post belongs to another user: 0 rows affected (RLS)
    -- - If active post owned by user: 1 row affected
    --
    -- All cases return success (no error on 0 rows).

    UPDATE daily_posts
    SET
        deleted_at = NOW(),
        updated_at = NOW()
    WHERE id = p_post_id
      AND deleted_at IS NULL;

    -- =========================================================================
    -- IMPORTANT: Date slot remains occupied
    -- =========================================================================
    -- The unique constraint idx_one_post_per_day is on (user_id, circle_id, posted_date)
    -- and is NOT a partial index (it includes deleted posts).
    --
    -- This means:
    -- 1. The deleted post still occupies the date slot
    -- 2. User cannot post again on the same day to the same circle
    -- 3. This is by design: "you showed up or you didn't"
    --
    -- The ring will still show the user as "posted" for that day,
    -- because the fetch_circle_state function counts posts regardless
    -- of deleted_at status.

END;
$$;

COMMENT ON FUNCTION delete_post IS
'Soft-deletes a post by setting deleted_at. Idempotent.
Enforces: AUTH_REQUIRED, user can only delete own posts.
Critical: Date slot remains occupied. User cannot repost same day.
The ring still shows "posted" for deleted posts.';
