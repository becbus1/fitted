-- =============================================================================
-- FITTED: join_circle RPC
-- =============================================================================
--
-- Adds user to an existing circle via invite code or circle ID.
-- Handles: new join, rejoin (reactivation), idempotent already-member.
--
-- INVARIANTS ENFORCED:
-- 1. Joining is idempotent (already member = success)
-- 2. Rejoin increments join_count (history preserved)
-- 3. One active membership per (user, circle) - via DB constraint
-- 4. Circle must exist and not be deleted
-- 5. User must be authenticated
--
-- SECURITY MODEL: DEFINER
-- Reason: Needs to read circles table (potentially not yet visible via RLS)
--         and perform upsert on memberships. Validates caller internally.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION join_circle(
    p_circle_id UUID DEFAULT NULL,
    p_invite_code TEXT DEFAULT NULL
)
RETURNS TABLE(
    circle_id UUID,
    name TEXT,
    member_count BIGINT,
    joined_at TIMESTAMPTZ,
    is_rejoin BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_circle circles%ROWTYPE;
    v_membership circle_memberships%ROWTYPE;
    v_is_rejoin BOOLEAN := FALSE;
    v_joined_at TIMESTAMPTZ;
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED'
            USING HINT = 'User must be authenticated to join a circle';
    END IF;

    -- Validate input: must provide one of circle_id or invite_code
    IF p_circle_id IS NULL AND (p_invite_code IS NULL OR p_invite_code = '') THEN
        RAISE EXCEPTION 'INVALID_INPUT'
            USING HINT = 'Must provide either circle_id or invite_code';
    END IF;

    -- =========================================================================
    -- RESOLVE CIRCLE
    -- =========================================================================

    IF p_circle_id IS NOT NULL THEN
        -- Join by circle ID (from deep link)
        SELECT * INTO v_circle
        FROM circles
        WHERE id = p_circle_id;
    ELSE
        -- Join by invite code (manual entry)
        -- Normalize: uppercase, trim whitespace
        SELECT * INTO v_circle
        FROM circles
        WHERE invite_code = UPPER(TRIM(p_invite_code));
    END IF;

    -- Check circle exists
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CIRCLE_NOT_FOUND'
            USING HINT = 'No circle found with the provided ID or invite code';
    END IF;

    -- Check circle not deleted
    IF v_circle.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CIRCLE_DELETED'
            USING HINT = 'This circle no longer exists';
    END IF;

    -- =========================================================================
    -- CHECK EXISTING MEMBERSHIP
    -- =========================================================================

    -- Lock the row if it exists to prevent race conditions
    SELECT * INTO v_membership
    FROM circle_memberships
    WHERE user_id = v_user_id
      AND circle_id = v_circle.id
    FOR UPDATE;

    IF FOUND THEN
        IF v_membership.left_at IS NULL THEN
            -- =====================================================================
            -- CASE 1: Already an active member
            -- =====================================================================
            -- Idempotent: return success without changes
            v_joined_at := v_membership.joined_at;
            v_is_rejoin := FALSE;

        ELSE
            -- =====================================================================
            -- CASE 2: Former member - reactivate
            -- =====================================================================
            UPDATE circle_memberships
            SET
                left_at = NULL,
                join_count = join_count + 1,
                updated_at = NOW()
            WHERE id = v_membership.id;

            v_joined_at := v_membership.joined_at;
            v_is_rejoin := TRUE;
        END IF;
    ELSE
        -- =====================================================================
        -- CASE 3: New member
        -- =====================================================================
        INSERT INTO circle_memberships (user_id, circle_id)
        VALUES (v_user_id, v_circle.id)
        RETURNING joined_at INTO v_joined_at;

        v_is_rejoin := FALSE;
    END IF;

    -- =========================================================================
    -- RETURN CIRCLE DATA
    -- =========================================================================

    RETURN QUERY
    SELECT
        v_circle.id AS circle_id,
        v_circle.name AS name,
        (
            SELECT COUNT(*)
            FROM circle_memberships cm
            WHERE cm.circle_id = v_circle.id
              AND cm.left_at IS NULL
        ) AS member_count,
        v_joined_at AS joined_at,
        v_is_rejoin AS is_rejoin;
END;
$$;

COMMENT ON FUNCTION join_circle IS
'Joins user to a circle by ID or invite code. Idempotent.
Enforces: AUTH_REQUIRED, circle exists, not deleted, one active membership.
Handles: new join, rejoin (increments join_count), already-member (no-op).';
