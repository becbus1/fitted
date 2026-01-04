# Fitted API Contract

Server-side contract between iOS client and Supabase backend.

**Principle:** The server is the source of truth. Client state is optimistic only. It must be impossible for the client to violate product rules, even with bugs.

---

## Invariant Enforcement Matrix

| Invariant | Database | Server | Client |
|-----------|----------|--------|--------|
| One post per (user, circle, day) | ✅ UNIQUE constraint | ✅ Pre-check | ⚠️ Optimistic |
| User must be member to post | ✅ FK + RLS | ✅ Validate | ⚠️ Optimistic |
| Soft delete blocks repost | ✅ Constraint includes deleted | ✅ Check exists | ❌ Cannot enforce |
| One active membership per (user, circle) | ✅ Partial unique index | ✅ Upsert logic | ⚠️ Optimistic |
| Leave doesn't delete posts | ✅ No CASCADE on membership | ✅ Separate tables | N/A |
| Calendar day uses user timezone | ❌ DB stores result | ✅ Calculates | ⚠️ Sends timezone |
| Invite codes are valid | ✅ FK constraint | ✅ Lookup | ⚠️ Optimistic |

**Legend:**
- ✅ = Enforced at this level
- ⚠️ = Optimistic/advisory only
- ❌ = Cannot enforce at this level

---

## Server Actions

### 1. `create_circle`

Creates a new circle and adds the creator as the first member.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `name` | String | No | Max 50 chars, defaults to "My Circle" |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Generate unique 6-char invite_code (retry on collision)
3. INSERT into circles (name, created_by_user_id, invite_code)
4. INSERT into circle_memberships (user_id, circle_id, joined_at)
5. Return circle record with invite_code and invite_url
```

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `INVALID_NAME` | Name > 50 chars or contains banned words | Show validation error |
| `SERVER_ERROR` | DB error | Retry with backoff |

#### Guarantees

- Circle is created atomically with creator's membership
- Invite code is unique and immediately usable
- Creator is always the first member

---

### 2. `join_circle`

Adds user to an existing circle via invite code or circle ID.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `circle_id` | UUID | One of these | Valid UUID |
| `invite_code` | String | One of these | 6 chars, alphanumeric |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Resolve circle:
   - If invite_code: SELECT circle_id FROM circles WHERE invite_code = ?
   - If circle_id: Validate circle exists and is not deleted
3. Check existing membership:
   - If active membership exists: Return success (idempotent)
   - If former membership exists: Reactivate (set left_at = NULL, increment join_count)
   - If no membership: INSERT new membership
4. Return circle record with member list
```

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `CIRCLE_NOT_FOUND` | Invalid code or ID | Show "Circle not found" |
| `CIRCLE_DELETED` | Circle was soft-deleted | Show "Circle no longer exists" |
| `ALREADY_MEMBER` | Active membership exists | Success (idempotent) |
| `SERVER_ERROR` | DB error | Retry with backoff |

#### Guarantees

- Joining is idempotent (safe to retry)
- Rejoin increments join_count (history preserved)
- Former membership records are preserved (left_at remains set on old record if we create new)

**Note:** The current schema reactivates the existing record. Alternative: create new record, keep old for history. Decision: reactivate for simplicity in v1.

---

### 3. `leave_circle`

Removes user from a circle without deleting their posts.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `circle_id` | UUID | Yes | Valid UUID |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Find active membership: SELECT * FROM circle_memberships
   WHERE user_id = ? AND circle_id = ? AND left_at IS NULL
3. If no active membership: Return success (idempotent)
4. UPDATE membership SET left_at = NOW()
5. Return success
```

#### What Happens to Posts

- **Posts are NOT deleted**
- Posts remain in user's personal archive
- Posts remain visible to circle members (as historical data)
- User cannot post to this circle until they rejoin

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `NOT_MEMBER` | No active membership | Success (idempotent) |
| `SERVER_ERROR` | DB error | Retry with backoff |

#### Guarantees

- Leaving is idempotent (safe to retry)
- Posts are never deleted by leave action
- Membership history is preserved (left_at is set, not deleted)

---

### 4. `post_fit`

Creates a daily post for a user in a circle.

**This is the most critical action. It enforces the core product constraint.**

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `circle_id` | UUID | Yes | User must be active member |
| `timezone` | String | Yes | Valid IANA timezone |
| `image_path` | String | Yes | Valid storage path |
| `image_width` | Integer | No | Positive integer |
| `image_height` | Integer | No | Positive integer |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Validate active membership exists
3. Calculate posted_date: (NOW() AT TIME ZONE timezone)::DATE
4. Check eligibility:
   SELECT EXISTS(
     SELECT 1 FROM daily_posts
     WHERE user_id = ? AND circle_id = ? AND posted_date = ?
   )
   - If exists (even deleted): REJECT
5. INSERT into daily_posts:
   - user_id, circle_id, posted_date, posted_at, posted_timezone, image_path
6. Return post record
```

#### Calendar Day Calculation

```
Server time (UTC):     2024-01-15 03:00:00 UTC
User timezone:         America/New_York (UTC-5)
Local time:            2024-01-14 22:00:00 EST
posted_date:           2024-01-14  ← This is the authoritative day
```

**The server calculates the date. The client only provides the timezone.**

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `NOT_MEMBER` | No active membership | Show "Join circle first" |
| `ALREADY_POSTED` | Post exists for this day | Show "Already posted today" |
| `ALREADY_POSTED_DELETED` | Deleted post exists | Show "Already posted today" (same message) |
| `INVALID_TIMEZONE` | Unrecognized IANA timezone | Use UTC fallback, log warning |
| `INVALID_IMAGE` | Image path doesn't exist | Show upload error |
| `SERVER_ERROR` | DB error | Retry with backoff |

#### Race Condition Handling

```
Scenario: User taps "Post" twice quickly

Request 1: Starts processing
Request 2: Starts processing
Request 1: INSERT succeeds
Request 2: INSERT fails (unique constraint violation)

Result: Exactly one post created. Second request gets ALREADY_POSTED.
```

The database constraint is the final authority. Server pre-checks are optimization only.

#### Guarantees

- Exactly one post per (user, circle, day) — enforced by DB
- Deleted posts still block reposting — enforced by DB
- Server calculates posted_date — client cannot manipulate
- Timezone is recorded for audit trail

---

### 5. `fetch_circle_state`

Returns the current state of a circle for display in CircleView.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `circle_id` | UUID | Yes | User must be active member |
| `timezone` | String | Yes | For calculating "today" |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Validate active membership exists
3. Calculate today: (NOW() AT TIME ZONE timezone)::DATE
4. Fetch circle metadata
5. Fetch active members with today's posting status:
   SELECT
     u.id, u.display_name,
     (dp.id IS NOT NULL) as has_posted_today
   FROM circle_memberships cm
   JOIN users u ON u.id = cm.user_id
   LEFT JOIN daily_posts dp ON dp.user_id = cm.user_id
     AND dp.circle_id = cm.circle_id
     AND dp.posted_date = today
     AND dp.deleted_at IS NULL
   WHERE cm.circle_id = ? AND cm.left_at IS NULL
6. Return circle state
```

#### Response Shape

```json
{
  "circle": {
    "id": "uuid",
    "name": "Daily Fits",
    "member_count": 5
  },
  "today": "2024-01-15",
  "members": [
    { "id": "uuid", "display_name": "Alex", "has_posted_today": true },
    { "id": "uuid", "display_name": "Jordan", "has_posted_today": false }
  ],
  "current_user": {
    "has_posted_today": false,
    "can_post": true
  },
  "completion": {
    "posted": 3,
    "total": 5
  }
}
```

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `NOT_MEMBER` | No active membership | Redirect to circle list |
| `CIRCLE_NOT_FOUND` | Circle doesn't exist | Redirect to circle list |
| `SERVER_ERROR` | DB error | Show cached state, retry |

#### Guarantees

- Returns consistent snapshot of circle state
- Member order is stable (by join date or alphabetical)
- Posting status reflects soft-deleted posts correctly (has_posted = true even if deleted)

**Note:** `has_posted_today` should be TRUE even if the post was deleted. The user used their slot.

Wait, let me reconsider. Looking at the query:
```sql
AND dp.deleted_at IS NULL
```

This means deleted posts show as NOT posted in the ring. But they still block reposting.

**Design decision:** Should deleted posts show in the ring?
- If yes: Ring shows "you participated" even though post is hidden
- If no: Ring shows incomplete, but you can't fix it

**Recommendation:** Show deleted posts as "posted" in the ring. The ring reflects participation, not visible content. Update the query to remove `deleted_at IS NULL` for the completion check.

Actually, this needs clarification. Two separate concerns:
1. **Ring completion:** Did user post today? (Yes, even if deleted)
2. **Visible posts:** What posts to display? (Only non-deleted)

Let me revise:

```sql
-- For ring/completion (includes deleted):
LEFT JOIN daily_posts dp ON dp.user_id = cm.user_id
  AND dp.circle_id = cm.circle_id
  AND dp.posted_date = today
  -- No deleted_at filter here

-- For displaying the actual post image:
-- Separate query with deleted_at IS NULL
```

---

### 6. `fetch_archive`

Returns the user's personal post history.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `timezone` | String | Yes | For date display formatting |
| `limit` | Integer | No | Default 50, max 200 |
| `before_date` | Date | No | For pagination |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Fetch posts:
   SELECT * FROM daily_posts
   WHERE user_id = ?
     AND deleted_at IS NULL
     AND (before_date IS NULL OR posted_date < before_date)
   ORDER BY posted_date DESC
   LIMIT ?
3. Group by month for display
4. Return archive data
```

#### Response Shape

```json
{
  "posts": [
    {
      "id": "uuid",
      "circle_id": "uuid",
      "circle_name": "Daily Fits",
      "posted_date": "2024-01-15",
      "image_url": "https://cdn.../signed-url",
      "posted_at": "2024-01-15T14:30:00Z"
    }
  ],
  "has_more": true,
  "next_before_date": "2024-01-01"
}
```

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `SERVER_ERROR` | DB error | Show cached, retry |

#### Guarantees

- Returns only the requesting user's posts
- Includes posts from circles user has left
- Excludes soft-deleted posts
- Ordered by date descending (newest first)
- Pagination is stable (date-based, not offset-based)

---

### 7. `delete_post` (Soft Delete)

Hides a post without freeing the date slot.

#### Inputs

| Field | Type | Required | Validation |
|-------|------|----------|------------|
| `user_id` | UUID | Yes | Must match authenticated user |
| `post_id` | UUID | Yes | Must belong to user |

#### Server Logic

```
1. Validate user_id matches auth.uid()
2. Validate post belongs to user
3. UPDATE daily_posts SET deleted_at = NOW() WHERE id = ?
4. Return success
```

#### What This Does NOT Do

- Does NOT free the date slot for reposting
- Does NOT remove the post from completion ring calculation
- Does NOT affect other users' view of completion status

#### Failure Modes

| Error | Condition | Client Action |
|-------|-----------|---------------|
| `AUTH_REQUIRED` | No valid session | Redirect to login |
| `POST_NOT_FOUND` | Post doesn't exist or not owned | Show error |
| `ALREADY_DELETED` | Post already deleted | Success (idempotent) |
| `SERVER_ERROR` | DB error | Retry with backoff |

#### Guarantees

- Deletion is idempotent
- Post is hidden but slot remains occupied
- User cannot repost the same day

---

## Error Response Format

All errors follow this structure:

```json
{
  "error": {
    "code": "ALREADY_POSTED",
    "message": "You have already posted to this circle today",
    "details": {
      "circle_id": "uuid",
      "posted_date": "2024-01-15",
      "existing_post_id": "uuid"
    }
  }
}
```

---

## Idempotency

All mutating actions are designed to be idempotent or safely retriable:

| Action | Idempotent? | Safe to Retry? |
|--------|-------------|----------------|
| `create_circle` | No (creates new) | Yes (dedup by request ID) |
| `join_circle` | Yes | Yes |
| `leave_circle` | Yes | Yes |
| `post_fit` | No | No (may get ALREADY_POSTED) |
| `delete_post` | Yes | Yes |

For `create_circle` and `post_fit`, clients should implement request deduplication using a client-generated request ID.

---

## Timezone Handling Summary

| Component | Responsibility |
|-----------|---------------|
| Client | Sends user's IANA timezone with each request |
| Server | Calculates `posted_date` as `(NOW() AT TIME ZONE tz)::DATE` |
| Database | Stores `posted_date` as DATE, `posted_timezone` for audit |

**The client never sends a date. The server always calculates it.**

This prevents:
- Client clock manipulation
- Timezone spoofing to post "yesterday"
- Ambiguity about which day a post belongs to

---

## Security Boundaries

1. **Authentication:** All actions require valid Supabase Auth session
2. **Authorization:** RLS policies enforce user can only access their own data + circle data
3. **Validation:** Server validates all inputs before DB operations
4. **Constraints:** Database constraints are the final authority

**Trust hierarchy:** Database > Server > Client

The client is never trusted. Even if client code has bugs, the server and database prevent invalid states.
