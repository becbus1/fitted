-- =============================================================================
-- FITTED: create_circle RPC
-- =============================================================================
--
-- Creates a new circle and adds the creator as the first member.
--
-- INVARIANTS ENFORCED:
-- 1. Circle is created atomically with creator's membership
-- 2. Invite code is unique (DB constraint, retry on collision)
-- 3. Creator is always the first member
-- 4. User must be authenticated
--
-- SECURITY MODEL: DEFINER
-- Reason: Performs INSERT into both circles and circle_memberships
--         in a single transaction. Bypasses RLS for atomic insert,
--         validates auth.uid() internally.
--
-- =============================================================================

CREATE OR REPLACE FUNCTION create_circle(
    p_name TEXT DEFAULT 'My Circle'
)
RETURNS TABLE(
    circle_id UUID,
    name TEXT,
    invite_code CHAR(6),
    invite_url TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_circle_id UUID;
    v_invite_code CHAR(6);
    v_attempts INT := 0;
    v_max_attempts INT := 5;
BEGIN
    -- =========================================================================
    -- VALIDATION
    -- =========================================================================

    -- Validate authentication
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED'
            USING HINT = 'User must be authenticated to create a circle';
    END IF;

    -- Validate name length
    IF length(COALESCE(p_name, '')) > 50 THEN
        RAISE EXCEPTION 'INVALID_NAME'
            USING HINT = 'Circle name must be 50 characters or less';
    END IF;

    -- Use default if empty
    IF COALESCE(p_name, '') = '' THEN
        p_name := 'My Circle';
    END IF;

    -- =========================================================================
    -- CREATE CIRCLE WITH UNIQUE INVITE CODE
    -- =========================================================================

    -- Retry loop for invite code collision
    LOOP
        v_invite_code := generate_invite_code();
        v_attempts := v_attempts + 1;

        BEGIN
            INSERT INTO circles (name, created_by_user_id, invite_code)
            VALUES (p_name, v_user_id, v_invite_code)
            RETURNING id INTO v_circle_id;

            -- Success, exit loop
            EXIT;

        EXCEPTION WHEN unique_violation THEN
            -- Invite code collision, retry
            IF v_attempts >= v_max_attempts THEN
                RAISE EXCEPTION 'SERVER_ERROR'
                    USING HINT = 'Failed to generate unique invite code after % attempts', v_max_attempts;
            END IF;
            -- Continue loop
        END;
    END LOOP;

    -- =========================================================================
    -- ADD CREATOR AS FIRST MEMBER
    -- =========================================================================

    -- This runs in the same transaction as circle creation.
    -- If this fails, the circle insert is rolled back.
    INSERT INTO circle_memberships (user_id, circle_id)
    VALUES (v_user_id, v_circle_id);

    -- =========================================================================
    -- RETURN CIRCLE DATA
    -- =========================================================================

    RETURN QUERY
    SELECT
        v_circle_id AS circle_id,
        p_name AS name,
        v_invite_code AS invite_code,
        'fitted://join/' || v_circle_id::TEXT AS invite_url,
        NOW() AS created_at;
END;
$$;

COMMENT ON FUNCTION create_circle IS
'Creates a new circle with the caller as first member. Atomic transaction.
Enforces: AUTH_REQUIRED, unique invite code, creator membership.';
