# Fitted Supabase Implementation Plan

Backend execution plan for the API contract. This document specifies HOW to implement each server action, not WHAT the product does.

---

## Implementation Strategy Overview

### Decision Matrix: RPC vs Edge Functions

| Action | Implementation | Rationale |
|--------|---------------|-----------|
| `create_circle` | **Postgres RPC** | Single transaction, no external calls |
| `join_circle` | **Postgres RPC** | Single transaction, idempotent upsert |
| `leave_circle` | **Postgres RPC** | Single UPDATE, trivial |
| `post_fit` | **Edge Function** | Requires storage validation, complex error handling |
| `fetch_circle_state` | **Postgres RPC** | Read-only, complex JOIN |
| `fetch_archive` | **Postgres RPC** | Read-only, paginated query |
| `delete_post` | **Postgres RPC** | Single UPDATE, trivial |

**Guiding principle:** Use Postgres RPC unless the action requires:
- External service calls (Storage API validation)
- Complex error response formatting
- Rate limiting or abuse prevention
- Request-level logging beyond DB logs

---

## 1. `create_circle`

### Implementation: Postgres RPC

```
Function name: create_circle
Schema: public
```

### Security Model

```
SECURITY DEFINER
SET search_path = public, pg_temp
```

**Why DEFINER:** The function performs INSERT into both `circles` and `circle_memberships` in a single transaction. Using DEFINER allows the function to bypass RLS for the atomic insert, then return only the caller's data. The function validates `auth.uid()` internally.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_name` | TEXT | Optional, defaults to 'My Circle', max 50 chars |

### Return Shape

```sql
RETURNS TABLE(
    circle_id UUID,
    name TEXT,
    invite_code CHAR(6),
    invite_url TEXT,
    created_at TIMESTAMPTZ
)
```

### Transaction Strategy

```
Single implicit transaction (Postgres function default)
No explicit locking required
Invite code collision handled by retry loop (max 5 attempts)
```

### Atomicity Requirements

**CRITICAL:** Circle creation and creator membership MUST be atomic.

```
1. Generate invite code
2. INSERT into circles
3. INSERT into circle_memberships (creator as first member)
4. RETURN circle data

If step 3 fails, step 2 is rolled back automatically.
```

### RLS Interaction

- **Bypass pattern:** SECURITY DEFINER bypasses RLS
- **Validation:** Function checks `auth.uid() IS NOT NULL`
- **Post-insert:** Caller can read their own circle via RLS (circles_select_member policy)

### Constraint Reliance

| Check | Mechanism |
|-------|-----------|
| User authenticated | Explicit: `auth.uid() IS NOT NULL` |
| Invite code unique | DB: `UNIQUE` constraint on `circles.invite_code` |
| Name length | Explicit: `length(p_name) <= 50` |

### Pseudocode

```
FUNCTION create_circle(p_name TEXT DEFAULT 'My Circle')
RETURNS TABLE(...) AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_circle_id UUID;
    v_invite_code CHAR(6);
    v_attempts INT := 0;
BEGIN
    -- Validate auth
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Validate name
    IF length(p_name) > 50 THEN
        RAISE EXCEPTION 'INVALID_NAME';
    END IF;

    -- Generate unique invite code with retry
    LOOP
        v_invite_code := generate_invite_code();  -- 6-char alphanumeric
        v_attempts := v_attempts + 1;

        BEGIN
            INSERT INTO circles (name, created_by_user_id, invite_code)
            VALUES (p_name, v_user_id, v_invite_code)
            RETURNING id INTO v_circle_id;

            EXIT;  -- Success
        EXCEPTION WHEN unique_violation THEN
            IF v_attempts >= 5 THEN
                RAISE EXCEPTION 'SERVER_ERROR: invite code generation failed';
            END IF;
        END;
    END LOOP;

    -- Add creator as first member (same transaction)
    INSERT INTO circle_memberships (user_id, circle_id)
    VALUES (v_user_id, v_circle_id);

    -- Return circle data
    RETURN QUERY
    SELECT
        v_circle_id,
        p_name,
        v_invite_code,
        'fitted://join/' || v_circle_id::TEXT,
        NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## 2. `join_circle`

### Implementation: Postgres RPC

```
Function name: join_circle
Schema: public
```

### Security Model

```
SECURITY DEFINER
SET search_path = public, pg_temp
```

**Why DEFINER:** Needs to read circles table (potentially not yet visible via RLS) and perform upsert on memberships. Validates caller internally.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_circle_id` | UUID | Optional, one of circle_id or invite_code required |
| `p_invite_code` | CHAR(6) | Optional, one of circle_id or invite_code required |

### Return Shape

```sql
RETURNS TABLE(
    circle_id UUID,
    name TEXT,
    member_count BIGINT,
    joined_at TIMESTAMPTZ,
    is_rejoin BOOLEAN
)
```

### Transaction Strategy

```
Single implicit transaction
Row-level lock on membership record during upsert
```

### Atomicity Requirements

**IMPORTANT:** Membership check and insert/update MUST be atomic to prevent race conditions.

```
1. Resolve circle (by ID or invite code)
2. Check existing membership
3. Either:
   a. Return existing (idempotent)
   b. Reactivate former membership
   c. Create new membership
```

### RLS Interaction

- **Bypass pattern:** SECURITY DEFINER bypasses RLS
- **circles_select_by_invite:** Not used; function reads directly
- **Post-join:** Caller can read circle via RLS (circles_select_member policy)

### Constraint Reliance

| Check | Mechanism |
|-------|-----------|
| Circle exists | Explicit: SELECT with NOT FOUND check |
| Circle not deleted | Explicit: `deleted_at IS NULL` check |
| One active membership | DB: `idx_active_membership` partial unique index |
| User authenticated | Explicit: `auth.uid() IS NOT NULL` |

### Pseudocode

```
FUNCTION join_circle(
    p_circle_id UUID DEFAULT NULL,
    p_invite_code CHAR(6) DEFAULT NULL
)
RETURNS TABLE(...) AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_circle circles%ROWTYPE;
    v_membership circle_memberships%ROWTYPE;
    v_is_rejoin BOOLEAN := FALSE;
BEGIN
    -- Validate auth
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Validate input
    IF p_circle_id IS NULL AND p_invite_code IS NULL THEN
        RAISE EXCEPTION 'INVALID_INPUT';
    END IF;

    -- Resolve circle
    IF p_circle_id IS NOT NULL THEN
        SELECT * INTO v_circle FROM circles WHERE id = p_circle_id;
    ELSE
        SELECT * INTO v_circle FROM circles
        WHERE invite_code = UPPER(p_invite_code);
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CIRCLE_NOT_FOUND';
    END IF;

    IF v_circle.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'CIRCLE_DELETED';
    END IF;

    -- Check existing membership (with row lock)
    SELECT * INTO v_membership
    FROM circle_memberships
    WHERE user_id = v_user_id AND circle_id = v_circle.id
    FOR UPDATE;

    IF FOUND THEN
        IF v_membership.left_at IS NULL THEN
            -- Already active member - return success (idempotent)
            -- No changes needed
        ELSE
            -- Former member - reactivate
            UPDATE circle_memberships
            SET left_at = NULL,
                join_count = join_count + 1,
                updated_at = NOW()
            WHERE id = v_membership.id;

            v_is_rejoin := TRUE;
        END IF;
    ELSE
        -- New membership
        INSERT INTO circle_memberships (user_id, circle_id)
        VALUES (v_user_id, v_circle.id);
    END IF;

    -- Return circle data
    RETURN QUERY
    SELECT
        v_circle.id,
        v_circle.name,
        (SELECT COUNT(*) FROM circle_memberships
         WHERE circle_id = v_circle.id AND left_at IS NULL),
        COALESCE(v_membership.joined_at, NOW()),
        v_is_rejoin;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## 3. `leave_circle`

### Implementation: Postgres RPC

```
Function name: leave_circle
Schema: public
```

### Security Model

```
SECURITY INVOKER
```

**Why INVOKER:** User is updating their own membership. RLS policy `memberships_update_own` already permits this. No bypass needed.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_circle_id` | UUID | Required |

### Return Shape

```sql
RETURNS VOID
```

(Success = no exception. Idempotent.)

### Transaction Strategy

```
Single UPDATE statement
No explicit locking (UPDATE acquires row lock implicitly)
```

### Atomicity Requirements

**None beyond single statement.** Posts are NOT affected by leave action (by design).

### RLS Interaction

- **memberships_update_own:** Applies. User can only update their own memberships.
- **No bypass needed**

### Constraint Reliance

| Check | Mechanism |
|-------|-----------|
| Membership exists | Implicit: UPDATE affects 0 rows (idempotent) |
| User owns membership | DB: RLS policy `memberships_update_own` |
| Posts not deleted | N/A: No cascade, separate table |

### Pseudocode

```
FUNCTION leave_circle(p_circle_id UUID)
RETURNS VOID AS $$
BEGIN
    -- Validate auth
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Update membership (RLS ensures ownership)
    -- Idempotent: if already left or never member, 0 rows affected
    UPDATE circle_memberships
    SET left_at = NOW()
    WHERE user_id = auth.uid()
      AND circle_id = p_circle_id
      AND left_at IS NULL;

    -- No error if 0 rows (idempotent)
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;
```

---

## 4. `post_fit`

### Implementation: Edge Function

```
Function name: post-fit
Runtime: Deno
Path: /functions/v1/post-fit
```

### Why Edge Function

1. **Storage validation:** Must verify `image_path` exists in Supabase Storage before inserting
2. **Complex error responses:** Multiple failure modes with detailed error objects
3. **Rate limiting:** Potential abuse vector (one request per user per circle per day)
4. **Audit logging:** May want request-level logging beyond DB

### Security Model

```
Authorization: Bearer <supabase_access_token>
Service role key: Required for storage checks
```

**Flow:**
1. Extract user from JWT (`auth.uid()` equivalent)
2. Use service role for storage validation
3. Use user context for DB operations

### Parameters (JSON body)

| Parameter | Type | Validation |
|-----------|------|------------|
| `circle_id` | UUID | Required, user must be active member |
| `timezone` | String | Required, valid IANA timezone |
| `image_path` | String | Required, must exist in storage |
| `image_width` | Integer | Optional |
| `image_height` | Integer | Optional |

### Return Shape

```json
{
    "post": {
        "id": "uuid",
        "circle_id": "uuid",
        "posted_date": "2024-01-15",
        "posted_at": "2024-01-15T14:30:00Z",
        "image_url": "https://..."
    }
}
```

### Transaction Strategy

```
Edge Function coordinates:
1. Storage check (non-transactional)
2. DB insert via RPC (transactional)

DB RPC: post_fit_internal (SECURITY DEFINER)
```

### Atomicity Requirements

**CRITICAL:** The DB insert must be atomic. The Edge Function provides orchestration only.

Race condition handling:
```
User taps "Post" twice quickly:
- Request 1: INSERT succeeds
- Request 2: INSERT fails (unique constraint)
- Result: Exactly one post

The database constraint is the final authority.
```

### RLS Interaction

- **Edge Function bypasses RLS** via service role for storage check
- **DB RPC uses SECURITY DEFINER** for atomic insert with validation
- **Post-insert:** User can read their post via RLS (`posts_select` policy)

### Constraint Reliance

| Check | Mechanism |
|-------|-----------|
| One post per day | DB: `idx_one_post_per_day` unique index |
| User is member | Explicit: membership check in RPC |
| Image exists | Edge Function: Storage API check |
| Valid timezone | Explicit: Postgres AT TIME ZONE (invalid = error) |

### Edge Function Pseudocode

```typescript
// POST /functions/v1/post-fit

import { createClient } from '@supabase/supabase-js'

Deno.serve(async (req) => {
    // 1. Auth
    const authHeader = req.headers.get('Authorization')
    const token = authHeader?.replace('Bearer ', '')

    const userClient = createClient(SUPABASE_URL, token)
    const { data: { user }, error: authError } = await userClient.auth.getUser()

    if (!user) {
        return Response.json({ error: { code: 'AUTH_REQUIRED' } }, { status: 401 })
    }

    // 2. Parse input
    const { circle_id, timezone, image_path, image_width, image_height } = await req.json()

    // 3. Validate image exists (service role)
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY)
    const { data: imageData, error: storageError } = await adminClient
        .storage
        .from('posts')
        .download(image_path)

    if (storageError) {
        return Response.json({
            error: { code: 'INVALID_IMAGE', message: 'Image not found' }
        }, { status: 400 })
    }

    // 4. Call internal RPC (handles all DB logic)
    const { data, error } = await adminClient.rpc('post_fit_internal', {
        p_user_id: user.id,
        p_circle_id: circle_id,
        p_timezone: timezone,
        p_image_path: image_path,
        p_image_width: image_width,
        p_image_height: image_height
    })

    if (error) {
        // Map RPC exceptions to HTTP responses
        const errorCode = parseErrorCode(error.message)
        return Response.json({ error: { code: errorCode } }, { status: 400 })
    }

    // 5. Generate signed URL for response
    const { data: signedUrl } = await adminClient
        .storage
        .from('posts')
        .createSignedUrl(image_path, 3600)

    return Response.json({
        post: {
            ...data,
            image_url: signedUrl
        }
    })
})
```

### Internal RPC Pseudocode

```
FUNCTION post_fit_internal(
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
) AS $$
DECLARE
    v_today DATE;
    v_post_id UUID;
BEGIN
    -- Calculate today in user's timezone
    BEGIN
        v_today := (NOW() AT TIME ZONE p_timezone)::DATE;
    EXCEPTION WHEN OTHERS THEN
        -- Invalid timezone, fall back to UTC
        v_today := (NOW() AT TIME ZONE 'UTC')::DATE;
    END;

    -- Validate membership
    IF NOT EXISTS (
        SELECT 1 FROM circle_memberships
        WHERE user_id = p_user_id
          AND circle_id = p_circle_id
          AND left_at IS NULL
    ) THEN
        RAISE EXCEPTION 'NOT_MEMBER';
    END IF;

    -- Check eligibility (pre-check, DB constraint is authoritative)
    IF EXISTS (
        SELECT 1 FROM daily_posts
        WHERE user_id = p_user_id
          AND circle_id = p_circle_id
          AND posted_date = v_today
    ) THEN
        RAISE EXCEPTION 'ALREADY_POSTED';
    END IF;

    -- Insert post
    -- Unique constraint handles race condition
    INSERT INTO daily_posts (
        user_id, circle_id, posted_date, posted_timezone,
        image_path, image_width, image_height
    )
    VALUES (
        p_user_id, p_circle_id, v_today, p_timezone,
        p_image_path, p_image_width, p_image_height
    )
    RETURNING id INTO v_post_id;

    RETURN QUERY
    SELECT v_post_id, p_circle_id, v_today, NOW();

EXCEPTION WHEN unique_violation THEN
    -- Race condition: another request won
    RAISE EXCEPTION 'ALREADY_POSTED';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

## 5. `fetch_circle_state`

### Implementation: Postgres RPC

```
Function name: fetch_circle_state
Schema: public
```

### Security Model

```
SECURITY INVOKER
```

**Why INVOKER:** Read-only. RLS policies already ensure user can only see circles they belong to.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_circle_id` | UUID | Required |
| `p_timezone` | TEXT | Required for calculating "today" |

### Return Shape

```sql
RETURNS JSONB
```

Shape:
```json
{
    "circle": { "id": "...", "name": "...", "member_count": 5 },
    "today": "2024-01-15",
    "members": [
        { "id": "...", "display_name": "...", "has_posted_today": true }
    ],
    "current_user": { "has_posted_today": false, "can_post": true },
    "completion": { "posted": 3, "total": 5 }
}
```

### Transaction Strategy

```
Read-only, no locking
Snapshot isolation (Postgres default)
```

### RLS Interaction

- **circles_select_member:** Applied. Validates caller is member.
- **memberships_select_circle:** Applied. Only sees members of circles they belong to.
- **posts_select:** Applied. Only sees posts from their circles.

If user is not a member, queries return empty (RLS filters).

### Constraint Reliance

All checks are implicit via RLS. No explicit validation needed.

### Pseudocode

```
FUNCTION fetch_circle_state(p_circle_id UUID, p_timezone TEXT)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_today DATE;
    v_result JSONB;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Calculate today
    v_today := (NOW() AT TIME ZONE COALESCE(p_timezone, 'UTC'))::DATE;

    -- Build response (RLS filters automatically)
    SELECT jsonb_build_object(
        'circle', jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'member_count', (
                SELECT COUNT(*) FROM circle_memberships
                WHERE circle_id = c.id AND left_at IS NULL
            )
        ),
        'today', v_today,
        'members', (
            SELECT jsonb_agg(jsonb_build_object(
                'id', u.id,
                'display_name', u.display_name,
                'has_posted_today', (
                    -- Posted = exists, even if deleted (ring shows participation)
                    EXISTS (
                        SELECT 1 FROM daily_posts dp
                        WHERE dp.user_id = u.id
                          AND dp.circle_id = c.id
                          AND dp.posted_date = v_today
                    )
                )
            ) ORDER BY cm.joined_at)
            FROM circle_memberships cm
            JOIN users u ON u.id = cm.user_id
            WHERE cm.circle_id = c.id AND cm.left_at IS NULL
        ),
        'current_user', jsonb_build_object(
            'has_posted_today', EXISTS (
                SELECT 1 FROM daily_posts
                WHERE user_id = v_user_id
                  AND circle_id = c.id
                  AND posted_date = v_today
            ),
            'can_post', NOT EXISTS (
                SELECT 1 FROM daily_posts
                WHERE user_id = v_user_id
                  AND circle_id = c.id
                  AND posted_date = v_today
            )
        ),
        'completion', jsonb_build_object(
            'posted', (
                SELECT COUNT(DISTINCT dp.user_id)
                FROM daily_posts dp
                JOIN circle_memberships cm ON cm.user_id = dp.user_id
                  AND cm.circle_id = dp.circle_id
                WHERE dp.circle_id = c.id
                  AND dp.posted_date = v_today
                  AND cm.left_at IS NULL
            ),
            'total', (
                SELECT COUNT(*) FROM circle_memberships
                WHERE circle_id = c.id AND left_at IS NULL
            )
        )
    ) INTO v_result
    FROM circles c
    WHERE c.id = p_circle_id
      AND c.deleted_at IS NULL;

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'CIRCLE_NOT_FOUND';
    END IF;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;
```

**Note on `has_posted_today`:** Per the API contract, this should be TRUE even if the post was deleted. The ring shows participation, not visible content. The query checks `EXISTS` without filtering `deleted_at`.

---

## 6. `fetch_archive`

### Implementation: Postgres RPC

```
Function name: fetch_archive
Schema: public
```

### Security Model

```
SECURITY INVOKER
```

**Why INVOKER:** Read-only, user's own data only. RLS policy `posts_select` ensures `user_id = auth.uid()`.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_limit` | INTEGER | Optional, default 50, max 200 |
| `p_before_date` | DATE | Optional, for pagination |

### Return Shape

```sql
RETURNS JSONB
```

Shape:
```json
{
    "posts": [
        {
            "id": "uuid",
            "circle_id": "uuid",
            "circle_name": "Daily Fits",
            "posted_date": "2024-01-15",
            "image_path": "posts/user-id/post-id.jpg",
            "posted_at": "2024-01-15T14:30:00Z"
        }
    ],
    "has_more": true,
    "next_before_date": "2024-01-01"
}
```

### Transaction Strategy

```
Read-only, no locking
Cursor-based pagination (date-based, stable)
```

### RLS Interaction

- **posts_select:** Applied. `user_id = auth.uid()` clause ensures only own posts.

### Pseudocode

```
FUNCTION fetch_archive(
    p_limit INTEGER DEFAULT 50,
    p_before_date DATE DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_limit INTEGER;
    v_posts JSONB;
    v_count INTEGER;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Clamp limit
    v_limit := LEAST(GREATEST(p_limit, 1), 200);

    -- Fetch posts with circle names
    SELECT jsonb_agg(post_row), COUNT(*)
    INTO v_posts, v_count
    FROM (
        SELECT jsonb_build_object(
            'id', dp.id,
            'circle_id', dp.circle_id,
            'circle_name', c.name,
            'posted_date', dp.posted_date,
            'image_path', dp.image_path,
            'posted_at', dp.posted_at
        ) as post_row
        FROM daily_posts dp
        JOIN circles c ON c.id = dp.circle_id
        WHERE dp.user_id = v_user_id
          AND dp.deleted_at IS NULL
          AND (p_before_date IS NULL OR dp.posted_date < p_before_date)
        ORDER BY dp.posted_date DESC
        LIMIT v_limit + 1  -- Fetch one extra to check has_more
    ) subq;

    -- Check if there are more
    RETURN jsonb_build_object(
        'posts', COALESCE(
            CASE WHEN v_count > v_limit
                 THEN v_posts - (v_count - 1)  -- Remove extra
                 ELSE v_posts
            END,
            '[]'::jsonb
        ),
        'has_more', v_count > v_limit,
        'next_before_date', (
            SELECT posted_date FROM daily_posts
            WHERE user_id = v_user_id
              AND deleted_at IS NULL
              AND (p_before_date IS NULL OR posted_date < p_before_date)
            ORDER BY posted_date DESC
            OFFSET v_limit - 1
            LIMIT 1
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;
```

---

## 7. `delete_post`

### Implementation: Postgres RPC

```
Function name: delete_post
Schema: public
```

### Security Model

```
SECURITY INVOKER
```

**Why INVOKER:** User is updating their own post. RLS policy `posts_update_own` permits this.

### Parameters

| Parameter | Type | Validation |
|-----------|------|------------|
| `p_post_id` | UUID | Required |

### Return Shape

```sql
RETURNS VOID
```

(Success = no exception. Idempotent.)

### Transaction Strategy

```
Single UPDATE statement
Implicit row lock
```

### Atomicity Requirements

None beyond single statement.

### RLS Interaction

- **posts_update_own:** Applied. `user_id = auth.uid()` ensures ownership.

### Constraint Reliance

| Check | Mechanism |
|-------|-----------|
| Post exists | Implicit via RLS (0 rows = idempotent success) |
| User owns post | DB: RLS policy |
| Date slot remains occupied | DB: No constraint change (unique index still includes deleted) |

### Pseudocode

```
FUNCTION delete_post(p_post_id UUID)
RETURNS VOID AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;

    -- Soft delete (RLS ensures ownership)
    -- Idempotent: already deleted = 0 rows affected
    UPDATE daily_posts
    SET deleted_at = NOW()
    WHERE id = p_post_id
      AND deleted_at IS NULL;

    -- No error if 0 rows (idempotent)
END;
$$ LANGUAGE plpgsql SECURITY INVOKER;
```

---

## Helper Functions

### `generate_invite_code`

```
FUNCTION generate_invite_code()
RETURNS CHAR(6) AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- Excludes I, O, 0, 1
    result TEXT := '';
    i INTEGER;
BEGIN
    FOR i IN 1..6 LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;
```

---

## Summary: Atomicity Requirements

| Action | Atomic? | Why | Mechanism |
|--------|---------|-----|-----------|
| `create_circle` | **YES** | Circle + membership must be created together | Single transaction |
| `join_circle` | **YES** | Check + insert/update must be atomic | Row lock + single transaction |
| `leave_circle` | No | Single UPDATE | N/A |
| `post_fit` | **YES** | Check + insert must be atomic (race condition) | Unique constraint + exception handling |
| `fetch_circle_state` | No | Read-only | N/A |
| `fetch_archive` | No | Read-only | N/A |
| `delete_post` | No | Single UPDATE | N/A |

---

## Summary: DB Constraint vs Explicit Logic

| Invariant | DB Constraint | Server Logic |
|-----------|---------------|--------------|
| One post per (user, circle, day) | `idx_one_post_per_day` | Pre-check (optimization) |
| One active membership per (user, circle) | `idx_active_membership` | Upsert logic |
| Soft delete blocks repost | Unique index includes deleted | N/A |
| User must be member to post | No FK (would be too restrictive) | Explicit check |
| Invite code unique | `UNIQUE` on `invite_code` | Retry loop |
| Valid dates (left_at >= joined_at) | `CHECK` constraint | N/A |

---

## RLS Policy Summary

| Table | Policy | Actions Affected | Bypass Pattern |
|-------|--------|------------------|----------------|
| circles | `circles_select_member` | `fetch_circle_state` | INVOKER (filters) |
| circles | `circles_select_by_invite` | N/A (unused, function reads directly) | N/A |
| circles | `circles_insert_auth` | `create_circle` | DEFINER |
| circle_memberships | `memberships_select_circle` | `fetch_circle_state` | INVOKER (filters) |
| circle_memberships | `memberships_insert_own` | `join_circle` | DEFINER |
| circle_memberships | `memberships_update_own` | `leave_circle` | INVOKER |
| daily_posts | `posts_select` | `fetch_archive`, `fetch_circle_state` | INVOKER (filters) |
| daily_posts | `posts_insert_own` | `post_fit` | DEFINER |
| daily_posts | `posts_update_own` | `delete_post` | INVOKER |

---

## Deployment Order

1. Deploy helper functions (`generate_invite_code`)
2. Deploy RPC functions in order:
   - `create_circle`
   - `join_circle`
   - `leave_circle`
   - `post_fit_internal`
   - `fetch_circle_state`
   - `fetch_archive`
   - `delete_post`
3. Deploy Edge Function (`post-fit`)
4. Configure Storage bucket and policies (separate doc)

---

## Open Questions for Implementation

1. **Rate limiting for `post_fit`:** Should we add server-side rate limiting beyond the one-per-day constraint?
2. **Image validation:** Should Edge Function validate image dimensions/format, or trust client?
3. **Signed URL expiry:** What TTL for image URLs in responses? (Current: 1 hour)
4. **Error code format:** Should we use Supabase's error format or custom?

These are implementation details, not product decisions.
