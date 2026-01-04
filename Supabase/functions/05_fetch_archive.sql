-- =============================================================================
-- FITTED: fetch_archive RPC
-- =============================================================================
--
-- Returns the user's personal post history.
-- Paginated by date (cursor-based, stable).
--
-- INVARIANTS ENFORCED:
-- 1. Returns only the requesting user's posts (via RLS)
-- 2. Includes posts from circles user has left
-- 3. Excludes soft-deleted posts
-- 4. Ordered by date descending (newest first)
-- 5. Pagination is stable (date-based, not offset-based)
--
-- SECURITY MODEL: INVOKER
-- Reason: Read-only, user's own data only. RLS policy posts_select
--         ensures user_id = auth.uid().
--
-- =============================================================================

CREATE OR REPLACE FUNCTION fetch_archive(
    p_limit INTEGER DEFAULT 50,
    p_before_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_limit INTEGER;
    v_posts JSONB;
    v_last_date DATE;
    v_has_more BOOLEAN;
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED'
            USING HINT = 'User must be authenticated to fetch archive';
    END IF;

    -- Clamp limit to valid range
    v_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);

    -- =========================================================================
    -- FETCH POSTS
    -- =========================================================================

    -- Fetch posts with pagination.
    -- We fetch limit + 1 to check if there are more results.
    -- Posts from circles user has left are included (archive preserves history).

    SELECT
        jsonb_agg(post_data ORDER BY post_data->>'posted_date' DESC),
        (COUNT(*) > v_limit)
    INTO v_posts, v_has_more
    FROM (
        SELECT jsonb_build_object(
            'id', dp.id,
            'circle_id', dp.circle_id,
            'circle_name', c.name,
            'posted_date', dp.posted_date,
            'posted_at', dp.posted_at,
            'image_path', dp.image_path,
            'image_width', dp.image_width,
            'image_height', dp.image_height
        ) AS post_data
        FROM daily_posts dp
        JOIN circles c ON c.id = dp.circle_id
        WHERE dp.user_id = v_user_id
          AND dp.deleted_at IS NULL
          AND (p_before_date IS NULL OR dp.posted_date < p_before_date)
        ORDER BY dp.posted_date DESC
        LIMIT v_limit + 1
    ) AS posts_subquery;

    -- Handle empty result
    IF v_posts IS NULL THEN
        v_posts := '[]'::jsonb;
        v_has_more := FALSE;
    END IF;

    -- If we fetched more than limit, trim the result
    IF v_has_more THEN
        -- Remove the extra item
        v_posts := (
            SELECT jsonb_agg(elem)
            FROM (
                SELECT elem
                FROM jsonb_array_elements(v_posts) WITH ORDINALITY arr(elem, idx)
                WHERE idx <= v_limit
            ) trimmed
        );
    END IF;

    -- =========================================================================
    -- DETERMINE NEXT PAGE CURSOR
    -- =========================================================================

    -- Get the last date for pagination cursor
    IF jsonb_array_length(v_posts) > 0 THEN
        v_last_date := (v_posts->-1->>'posted_date')::DATE;
    ELSE
        v_last_date := NULL;
    END IF;

    -- =========================================================================
    -- BUILD AND RETURN RESPONSE
    -- =========================================================================

    RETURN jsonb_build_object(
        'posts', v_posts,
        'has_more', v_has_more,
        'next_before_date', v_last_date
    );
END;
$$;

COMMENT ON FUNCTION fetch_archive IS
'Returns user''s personal post history with pagination.
Enforces: AUTH_REQUIRED, returns only own posts.
Includes: Posts from circles user has left.
Excludes: Soft-deleted posts.
Pagination: Cursor-based by date (stable ordering).';
