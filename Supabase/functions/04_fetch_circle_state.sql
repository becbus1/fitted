-- =============================================================================
-- FITTED: fetch_circle_state RPC
-- =============================================================================
--
-- Returns the current state of a circle for display in CircleView.
-- Includes: circle metadata, member list with posting status, completion stats.
--
-- INVARIANTS ENFORCED:
-- 1. User can only fetch circles they are a member of (via RLS)
-- 2. has_posted_today is TRUE even if post was deleted (slot is used)
-- 3. Member order is stable (by join date)
-- 4. Today is calculated in user's provided timezone
--
-- SECURITY MODEL: INVOKER
-- Reason: Read-only. RLS policies ensure user can only see circles they
--         belong to and members of those circles.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION fetch_circle_state(
    p_circle_id UUID,
    p_timezone TEXT DEFAULT 'UTC'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
STABLE
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_today DATE;
    v_circle_data JSONB;
    v_members_data JSONB;
    v_current_user_posted BOOLEAN;
    v_total_members BIGINT;
    v_posted_today BIGINT;
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED'
            USING HINT = 'User must be authenticated to fetch circle state';
    END IF;

    -- Validate input
    IF p_circle_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'circle_id is required';
    END IF;

    -- =========================================================================
    -- CALCULATE TODAY
    -- =========================================================================

    -- Calculate "today" in user's timezone
    -- If timezone is invalid, fall back to UTC
    BEGIN
        v_today := (NOW() AT TIME ZONE COALESCE(p_timezone, 'UTC'))::DATE;
    EXCEPTION WHEN OTHERS THEN
        v_today := (NOW() AT TIME ZONE 'UTC')::DATE;
    END;

    -- =========================================================================
    -- VERIFY MEMBERSHIP (RLS will also enforce this)
    -- =========================================================================

    -- Check user is an active member of this circle
    IF NOT EXISTS (
        SELECT 1 FROM circle_memberships
        WHERE user_id = v_user_id
          AND circle_id = p_circle_id
          AND left_at IS NULL
    ) THEN
        RAISE EXCEPTION 'NOT_MEMBER'
            USING HINT = 'User is not a member of this circle';
    END IF;

    -- =========================================================================
    -- FETCH CIRCLE DATA
    -- =========================================================================

    SELECT jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'invite_code', c.invite_code,
        'created_at', c.created_at
    )
    INTO v_circle_data
    FROM circles c
    WHERE c.id = p_circle_id
      AND c.deleted_at IS NULL;

    IF v_circle_data IS NULL THEN
        RAISE EXCEPTION 'CIRCLE_NOT_FOUND'
            USING HINT = 'Circle does not exist or has been deleted';
    END IF;

    -- =========================================================================
    -- FETCH MEMBERS WITH POSTING STATUS
    -- =========================================================================

    -- Note on has_posted_today:
    -- We check if a post EXISTS for (user, circle, today).
    -- We do NOT filter by deleted_at here.
    -- A deleted post still means the user "used" their slot.
    -- The ring shows participation, not visible content.

    SELECT jsonb_agg(
        jsonb_build_object(
            'id', member_row.user_id,
            'display_name', member_row.display_name,
            'has_posted_today', member_row.has_posted_today,
            'joined_at', member_row.joined_at
        )
        ORDER BY member_row.joined_at ASC
    )
    INTO v_members_data
    FROM (
        SELECT
            cm.user_id,
            u.display_name,
            cm.joined_at,
            EXISTS (
                SELECT 1 FROM daily_posts dp
                WHERE dp.user_id = cm.user_id
                  AND dp.circle_id = cm.circle_id
                  AND dp.posted_date = v_today
                -- Note: NO deleted_at filter here
                -- Deleted posts still count as "posted"
            ) AS has_posted_today
        FROM circle_memberships cm
        JOIN users u ON u.id = cm.user_id
        WHERE cm.circle_id = p_circle_id
          AND cm.left_at IS NULL
    ) AS member_row;

    -- Handle empty circle (shouldn't happen, but be safe)
    IF v_members_data IS NULL THEN
        v_members_data := '[]'::jsonb;
    END IF;

    -- =========================================================================
    -- CALCULATE COMPLETION STATS
    -- =========================================================================

    -- Total active members
    SELECT COUNT(*)
    INTO v_total_members
    FROM circle_memberships
    WHERE circle_id = p_circle_id
      AND left_at IS NULL;

    -- Members who have posted today (including deleted posts)
    SELECT COUNT(DISTINCT dp.user_id)
    INTO v_posted_today
    FROM daily_posts dp
    JOIN circle_memberships cm
      ON cm.user_id = dp.user_id
     AND cm.circle_id = dp.circle_id
    WHERE dp.circle_id = p_circle_id
      AND dp.posted_date = v_today
      AND cm.left_at IS NULL;
    -- Note: NO deleted_at filter - deleted posts count toward completion

    -- =========================================================================
    -- CHECK CURRENT USER'S STATUS
    -- =========================================================================

    -- Has current user posted today (including deleted)?
    SELECT EXISTS (
        SELECT 1 FROM daily_posts
        WHERE user_id = v_user_id
          AND circle_id = p_circle_id
          AND posted_date = v_today
        -- Note: NO deleted_at filter
    )
    INTO v_current_user_posted;

    -- =========================================================================
    -- BUILD AND RETURN RESPONSE
    -- =========================================================================

    RETURN jsonb_build_object(
        'circle', v_circle_data || jsonb_build_object(
            'member_count', v_total_members
        ),
        'today', v_today,
        'members', v_members_data,
        'current_user', jsonb_build_object(
            'has_posted_today', v_current_user_posted,
            'can_post', NOT v_current_user_posted
        ),
        'completion', jsonb_build_object(
            'posted', v_posted_today,
            'total', v_total_members
        )
    );
END;
$$;

COMMENT ON FUNCTION fetch_circle_state IS
'Returns circle state for CircleView display.
Enforces: AUTH_REQUIRED, user must be member.
Includes: circle metadata, members with posting status, completion stats.
Note: has_posted_today is TRUE even for deleted posts (slot is used).';
