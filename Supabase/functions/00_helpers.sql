-- =============================================================================
-- FITTED: Helper Functions
-- =============================================================================
--
-- Utility functions used by RPC functions.
-- Must be deployed before RPC functions.
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- generate_invite_code
-- -----------------------------------------------------------------------------
-- Generates a 6-character alphanumeric invite code.
-- Excludes ambiguous characters: I, O, 0, 1
--
-- Used by: create_circle
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION generate_invite_code()
RETURNS CHAR(6)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Alphabet excludes ambiguous characters: I, O, 0, 1
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    result TEXT := '';
    i INTEGER;
BEGIN
    FOR i IN 1..6 LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$;

COMMENT ON FUNCTION generate_invite_code IS
'Generates 6-char alphanumeric code excluding ambiguous chars (I, O, 0, 1).';
