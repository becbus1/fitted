# Fitted Edge Functions

Production-grade Edge Functions for the Fitted posting flow.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              iOS CLIENT                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 1. POST /request-upload-url
                                    │    { circle_id, timezone, content_type }
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         request-upload-url                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ Validate    │→ │ Check       │→ │ Check       │→ │ Generate            │ │
│  │ JWT         │  │ Membership  │  │ Eligibility │  │ signed PUT URL      │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Response: { upload_url, post_id, expires_at }
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              iOS CLIENT                                      │
│                         (captures photo)                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 2. PUT to signed URL
                                    │    (direct to Storage)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         SUPABASE STORAGE                                     │
│                    posts/{user_id}/{post_id}.jpg                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ 3. POST /post-fit
                                    │    { circle_id, timezone, post_id }
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              post-fit                                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ Validate    │→ │ Check       │→ │ Verify      │→ │ Call                │ │
│  │ JWT         │  │ Replay      │  │ Image Exists│  │ post_fit_internal   │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Response: { post: { id, image_url, ... } }
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              iOS CLIENT                                      │
│                      (updates UI, shows in ring)                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Edge Functions

### 1. `request-upload-url`

**Purpose:** Generate signed URL for direct image upload.

**Called:** Before photo capture (to fail fast on ineligibility).

| Step | Action | Invariant Protected |
|------|--------|---------------------|
| 1 | Validate JWT | Only authenticated users |
| 2 | Check circle exists | Circle must exist |
| 3 | Check membership | Must be active member |
| 4 | Check eligibility | One post per day (pre-check) |
| 5 | Generate post_id | Server controls path |
| 6 | Create signed URL | Path-scoped, time-limited |

**Request:**
```json
{
  "circle_id": "uuid",
  "timezone": "America/New_York",
  "content_type": "image/jpeg"
}
```

**Response:**
```json
{
  "upload_url": "https://...supabase.co/storage/v1/object/upload/sign/posts/...",
  "post_id": "uuid",
  "expires_at": "2024-01-15T15:00:00Z",
  "image_path": "user-id/post-id.jpg"
}
```

**Errors:**

| Code | Status | Cause |
|------|--------|-------|
| `AUTH_REQUIRED` | 401 | Invalid/missing JWT |
| `INVALID_INPUT` | 400 | Bad request body |
| `CIRCLE_NOT_FOUND` | 404 | Circle doesn't exist |
| `NOT_MEMBER` | 403 | Not a circle member |
| `ALREADY_POSTED` | 409 | Already posted today |
| `SERVER_ERROR` | 500 | Unexpected failure |

---

### 2. `post-fit`

**Purpose:** Create post record after image upload.

**Called:** After successful PUT to Storage.

| Step | Action | Invariant Protected |
|------|--------|---------------------|
| 1 | Validate JWT | Only authenticated users |
| 2 | Check replay | Post ID used only once |
| 3 | Verify image | Image exists at path |
| 4 | Verify path | Path matches user ID |
| 5 | Call RPC | Atomic insert with constraints |
| 6 | Generate URL | Signed delivery URL |

**Request:**
```json
{
  "circle_id": "uuid",
  "timezone": "America/New_York",
  "post_id": "uuid",
  "image_width": 1080,
  "image_height": 1920
}
```

**Response:**
```json
{
  "post": {
    "id": "uuid",
    "circle_id": "uuid",
    "posted_date": "2024-01-15",
    "posted_at": "2024-01-15T14:30:00Z",
    "image_url": "https://ik.imagekit.io/fitted/posts/..."
  }
}
```

**Errors:**

| Code | Status | Cause |
|------|--------|-------|
| `AUTH_REQUIRED` | 401 | Invalid/missing JWT |
| `INVALID_INPUT` | 400 | Bad request body |
| `POST_ID_REUSED` | 409 | Post ID already exists |
| `IMAGE_NOT_FOUND` | 400 | Image not in Storage |
| `IMAGE_PATH_MISMATCH` | 403 | Path doesn't match user |
| `NOT_MEMBER` | 403 | Not a circle member |
| `ALREADY_POSTED` | 409 | Already posted today |
| `SERVER_ERROR` | 500 | Unexpected failure |

---

## Security Properties

### Replay Attack Prevention

**Attack:** Reuse a post_id to create multiple posts or resurrect deleted posts.

**Defense:**
```
Step 3 in post-fit:
1. Query daily_posts for existing post_id
2. If found (even if deleted), return POST_ID_REUSED
3. post_id can never be reused
```

### Path Injection Prevention

**Attack:** Claim another user's image by specifying their path.

**Defense:**
```
1. request-upload-url generates path as {auth.uid()}/{server-generated-uuid}.{ext}
2. Storage RLS only allows uploads to user's own folder
3. post-fit verifies path starts with authenticated user's ID
```

### Race Condition Handling

**Scenario:** Two concurrent post-fit calls with different post_ids.

**Defense:**
```
1. post_fit_internal checks eligibility
2. INSERT with unique constraint on (user_id, circle_id, posted_date)
3. First INSERT succeeds
4. Second INSERT fails with unique_violation → ALREADY_POSTED
5. Orphaned image in Storage (harmless, private bucket)
```

### URL Guessing Prevention

**Attack:** Guess image paths to access other users' photos.

**Defense:**
```
1. Storage bucket is private (no public access)
2. Delivery URLs are signed (ImageKit HMAC)
3. Signatures include path + expiry
4. UUIDs have 2^128 entropy (unguessable)
```

### Signed URL Scope

**Attack:** Use upload URL for different path or method.

**Defense:**
```
1. Supabase signed upload URL is path-specific
2. URL only valid for PUT method
3. URL expires in 5 minutes
4. upsert: false prevents overwrites
```

---

## Failure Modes and Recovery

### Client Flow with Error Handling

```
iOS Client:

1. Call request-upload-url
   ├── Success: Got upload_url and post_id
   └── Error: Show appropriate UI message, stop flow

2. Capture photo

3. PUT to upload_url
   ├── Success: 204 No Content
   └── Error: Retry upload (URL valid for 5 min)

4. Call post-fit with post_id
   ├── Success: Show post in ring
   ├── ALREADY_POSTED: User somehow posted elsewhere
   ├── IMAGE_NOT_FOUND: Upload failed silently, retry from step 3
   └── POST_ID_REUSED: Bug or attack, start over from step 1
```

### Partial Failure Scenarios

| Failure Point | State | Recovery |
|---------------|-------|----------|
| After request-upload-url | URL generated, no upload | URL expires in 5 min, no cleanup needed |
| After PUT, before post-fit | Image in Storage, no record | Orphaned image (harmless), user can retry |
| During post-fit RPC | Depends on failure point | RPC is atomic, either succeeds or rolls back |
| After post-fit, before response | Post created | Client retries, gets POST_ID_REUSED, can fetch state |

### Orphaned Image Cleanup (Optional)

```sql
-- Find images with no matching post
SELECT name FROM storage.objects
WHERE bucket_id = 'posts'
  AND created_at < NOW() - INTERVAL '1 hour'
  AND NOT EXISTS (
    SELECT 1 FROM daily_posts
    WHERE image_path = 'posts/' || objects.name
  );

-- Run weekly, delete if desired
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SUPABASE_URL` | Project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Service role key (for admin operations) |
| `IMAGEKIT_URL_ENDPOINT` | ImageKit URL endpoint (e.g., `https://ik.imagekit.io/fitted`) |
| `IMAGEKIT_PRIVATE_KEY` | ImageKit private key for URL signing |

---

## Deployment

```bash
# Deploy request-upload-url
supabase functions deploy request-upload-url --project-ref <ref>

# Deploy post-fit
supabase functions deploy post-fit --project-ref <ref>

# Set secrets
supabase secrets set IMAGEKIT_URL_ENDPOINT=https://ik.imagekit.io/fitted
supabase secrets set IMAGEKIT_PRIVATE_KEY=your_private_key
```

---

## Testing Checklist

### Happy Path
- [ ] Authenticated user can request upload URL
- [ ] User can PUT image to signed URL
- [ ] User can call post-fit to create record
- [ ] Response includes valid signed ImageKit URL

### Error Cases
- [ ] Unauthenticated request returns 401
- [ ] Non-member returns 403
- [ ] Already posted returns 409
- [ ] Invalid post_id format returns 400
- [ ] Reused post_id returns 409
- [ ] Missing image returns 400

### Security
- [ ] Cannot upload to another user's path
- [ ] Cannot create post with another user's image
- [ ] Signed URL expires after TTL
- [ ] Cannot overwrite existing image

### Race Conditions
- [ ] Two concurrent requests: only one succeeds
- [ ] Second request gets ALREADY_POSTED
