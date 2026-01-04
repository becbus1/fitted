# Fitted Image Pipeline Design

Security and cost design for image upload (Supabase Storage) and delivery (ImageKit).

**Principles:**
- Images are write-once, never modified
- Storage is private; all access is authenticated
- Delivery is via CDN with signed URLs
- Deleted posts hide images but don't free storage (audit trail)

---

## 1. Supabase Storage Bucket Configuration

### Bucket Definition

```
Bucket name: posts
Public: false (CRITICAL)
File size limit: 10 MB
Allowed MIME types: image/jpeg, image/heic, image/png
```

### Naming Convention

```
Pattern: {user_id}/{post_id}.{ext}

Example: 550e8400-e29b-41d4-a716-446655440000/7c9e6679-7425-40de-944b-e07fc1f90ae7.jpg
```

**Why this structure:**
- User ID prefix enables per-user RLS policies
- Post ID is the filename (1:1 mapping, no ambiguity)
- Extension preserved for MIME type hints to CDN
- Flat structure within user folder (no date hierarchy needed)

### Lifecycle Rules

| Rule | Configuration | Rationale |
|------|---------------|-----------|
| Retention | Indefinite | Posts are never hard-deleted |
| Versioning | Disabled | Immutability enforced at write time |
| Multipart cleanup | 24 hours | Abort incomplete uploads |

**No automatic deletion.** Even soft-deleted posts retain their images for:
- Audit trail
- Potential undelete feature
- Legal compliance

### RLS Policies

```sql
-- Bucket: posts

-- Policy: Users can upload to their own folder only
CREATE POLICY "users_upload_own"
ON storage.objects
FOR INSERT
WITH CHECK (
    bucket_id = 'posts'
    AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Policy: Users can read their own images
CREATE POLICY "users_read_own"
ON storage.objects
FOR SELECT
USING (
    bucket_id = 'posts'
    AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Policy: No updates allowed (immutability)
-- (No UPDATE policy = no updates)

-- Policy: No deletes allowed (soft delete only via DB)
-- (No DELETE policy = no deletes)
```

**Key security property:** Users cannot overwrite or delete objects. Only INSERT and SELECT are permitted.

---

## 2. Signed Upload URL Flow

### Flow Overview

```
┌─────────┐         ┌──────────────┐         ┌─────────────────┐
│  iOS    │         │ Edge Function│         │ Supabase Storage│
│  Client │         │ (post-fit)   │         │                 │
└────┬────┘         └──────┬───────┘         └────────┬────────┘
     │                     │                          │
     │ 1. Request upload   │                          │
     │    URL for post     │                          │
     │ ───────────────────>│                          │
     │                     │                          │
     │                     │ 2. Validate user         │
     │                     │    Generate post_id      │
     │                     │    Check not duplicate   │
     │                     │                          │
     │                     │ 3. Create signed         │
     │                     │    upload URL            │
     │                     │ ─────────────────────────>
     │                     │                          │
     │                     │<─────────────────────────│
     │                     │    Signed URL            │
     │                     │                          │
     │ 4. Return signed    │                          │
     │    URL + post_id    │                          │
     │<────────────────────│                          │
     │                     │                          │
     │ 5. PUT image to     │                          │
     │    signed URL       │                          │
     │ ───────────────────────────────────────────────>
     │                     │                          │
     │<───────────────────────────────────────────────│
     │    204 No Content   │                          │
     │                     │                          │
     │ 6. Confirm upload   │                          │
     │    complete         │                          │
     │ ───────────────────>│                          │
     │                     │                          │
     │                     │ 7. Verify object exists  │
     │                     │ ─────────────────────────>
     │                     │                          │
     │                     │ 8. Insert daily_posts    │
     │                     │    record                │
     │                     │                          │
     │ 9. Return post      │                          │
     │    with image URL   │                          │
     │<────────────────────│                          │
     │                     │                          │
```

### Who Generates Signed Upload URLs

**Edge Function: `post-fit`**

The Edge Function generates signed upload URLs using the service role key. This ensures:
- User is authenticated before any URL is issued
- Post ID is server-generated (prevents client from choosing path)
- Eligibility is checked before upload (no wasted bandwidth)

### Signed URL Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| TTL | 5 minutes | Enough for slow networks, limits exposure |
| Method | PUT only | No GET, POST, DELETE |
| Content-Type | Locked to request type | Prevents MIME mismatch |
| Path | `{user_id}/{post_id}.{ext}` | Server-generated, not client-controlled |

### Edge Function: Request Upload URL

```typescript
// POST /functions/v1/request-upload-url
// Called BEFORE image capture to pre-authorize

interface RequestUploadInput {
    circle_id: string;
    timezone: string;
    content_type: 'image/jpeg' | 'image/heic' | 'image/png';
}

interface RequestUploadOutput {
    upload_url: string;      // Signed PUT URL
    post_id: string;         // Server-generated UUID
    expires_at: string;      // ISO timestamp
}
```

**Server logic:**
1. Authenticate user
2. Validate circle membership
3. Check posting eligibility (not already posted today)
4. Generate post_id (UUID)
5. Determine file extension from content_type
6. Generate signed upload URL for `{user_id}/{post_id}.{ext}`
7. Return URL with 5-minute TTL

**Important:** The daily_posts record is NOT created at this stage. It's created only after upload confirmation.

### Edge Function: Confirm Upload

```typescript
// POST /functions/v1/confirm-upload
// Called AFTER successful PUT to storage

interface ConfirmUploadInput {
    post_id: string;
    circle_id: string;
    timezone: string;
    image_width?: number;
    image_height?: number;
}
```

**Server logic:**
1. Authenticate user
2. Verify object exists at `{user_id}/{post_id}.*`
3. Verify posting eligibility (race condition check)
4. Insert into daily_posts
5. Return post record with delivery URL

---

## 3. Immutability Enforcement

### Object Naming

```
Path: posts/{user_id}/{post_id}.{ext}

Components:
- user_id: From auth.uid() (server-verified)
- post_id: Server-generated UUID (client cannot choose)
- ext: Derived from Content-Type (jpeg, heic, png)
```

**Immutability by design:** The path includes the post_id. Since post_id is unique and server-generated, each upload creates a new path. There is no "update" operation.

### Overwrite Prevention

**Layer 1: RLS Policy**
```sql
-- No UPDATE policy exists. Updates are impossible via client.
```

**Layer 2: Signed URL Scope**
```
The signed URL is for a specific path that doesn't exist yet.
If the path already exists (duplicate request), the Edge Function
returns an error before generating a new URL.
```

**Layer 3: Storage Check Before Confirm**
```
Before inserting daily_posts, Edge Function verifies:
1. Object exists (upload succeeded)
2. Object was created recently (within TTL window)
3. No daily_posts record exists for this post_id
```

### Server-Side Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| User cannot choose path | post_id is server-generated UUID |
| User cannot overwrite | No UPDATE policy, no re-issue of same path |
| User cannot delete | No DELETE policy on storage |
| Image matches post | post_id in path = post_id in daily_posts |
| No orphan images | Multipart cleanup after 24h; unused URLs expire |

### Handling Abandoned Uploads

```
Scenario: User requests upload URL but never uploads

1. Signed URL expires after 5 minutes
2. No daily_posts record created (requires confirm step)
3. No storage object exists
4. User can request new upload URL (new post_id)

Result: No orphan state. Clean retry path.
```

```
Scenario: User uploads but doesn't confirm

1. Image exists in storage
2. No daily_posts record
3. Image is orphaned but harmless (private bucket)
4. User can request new upload URL (new post_id)
5. Old image remains but is unreferenced

Cleanup: Weekly job to delete objects with no matching daily_posts record
(optional, not required for correctness)
```

---

## 4. ImageKit Delivery Strategy

### ImageKit Configuration

```
Account type: Standard
Origin: Supabase Storage (private)
Authentication: Required (signed URLs)
```

### URL Structure

```
Pattern:
https://ik.imagekit.io/{imagekit_id}/posts/{user_id}/{post_id}.{ext}?{transforms}&{signature}

Example:
https://ik.imagekit.io/fitted/posts/550e8400.../7c9e6679....jpg?tr=w-400,h-400,fo-auto&ik-s=abc123&ik-t=1704067200
```

### URL Generation

**Who generates:** Edge Function or Postgres function

**When:**
- `fetch_circle_state`: Generate URLs for today's member thumbnails
- `fetch_archive`: Generate URLs for archive grid
- `confirm-upload`: Generate URL for the new post

### Transformation Presets

Define a limited set of allowed transformations to control costs:

| Preset | Parameters | Use Case |
|--------|------------|----------|
| `thumb` | `tr=w-200,h-200,fo-auto,c-at_max` | Member grid, archive grid |
| `preview` | `tr=w-600,h-800,fo-auto,c-at_max` | Post detail view |
| `full` | `tr=w-1200,h-1600,fo-auto,c-at_max,q-80` | Full-screen view |

**`fo-auto`:** Auto-focus on faces/subjects
**`c-at_max`:** Constrain to max dimensions, preserve aspect ratio
**`q-80`:** Quality 80% for full size (balance quality/size)

### Signed URL Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| TTL | 1 hour | Balance security/UX; refresh on app foreground |
| Scope | Specific path + transforms | Prevent transform abuse |
| Signature | HMAC-SHA256 | ImageKit default |

### URL Signing (ImageKit)

```
Base URL: https://ik.imagekit.io/fitted/posts/{path}?{transforms}

Signed URL adds:
- ik-t: Expiry timestamp (Unix seconds)
- ik-s: Signature (HMAC of path + transforms + expiry)

Example:
?tr=w-200,h-200&ik-t=1704067200&ik-s=a1b2c3d4...
```

### Cache Headers

ImageKit automatically sets cache headers. Configuration:

| Header | Value | Rationale |
|--------|-------|-----------|
| Cache-Control | `public, max-age=31536000, immutable` | Images never change |
| CDN cache | 1 year | Immutable content |
| Browser cache | 1 year | Reduce re-fetches |

**Why aggressive caching is safe:**
- Images are immutable (post_id in path)
- Deleted posts = different path (never reused)
- No cache invalidation needed

### Origin Fetch (ImageKit → Supabase)

ImageKit must authenticate to fetch from private Supabase Storage.

**Option A: Service Account URL (Recommended)**
```
Configure ImageKit origin with Supabase service role key:
Origin URL: https://{project}.supabase.co/storage/v1/object/posts
Headers:
  Authorization: Bearer {service_role_key}
```

**Option B: Signed Origin URLs**
```
Generate Supabase signed URLs with long TTL (24h)
Pass to ImageKit as origin
More complex, not recommended
```

---

## 5. Deleted Posts Handling

### What "Delete" Means

```
User action: Delete post
DB change: daily_posts.deleted_at = NOW()
Storage change: NONE (image preserved)
CDN change: NONE (cached copies remain)
Repost eligibility: BLOCKED (date slot occupied)
```

### Why Images Are Preserved

1. **Audit trail:** May need for abuse reports, legal requests
2. **No cache invalidation:** Cached copies exist; deleting origin is pointless
3. **Repost prevention:** Physical existence reinforces constraint
4. **Simplicity:** No async deletion job, no failure modes

### How Deleted Posts Affect Delivery

| Query | Includes Deleted? | Image URL Returned? |
|-------|-------------------|---------------------|
| `fetch_circle_state` (ring) | Yes (for completion count) | No (only shows "posted") |
| `fetch_circle_state` (images) | No | N/A |
| `fetch_archive` | No | N/A |
| Direct post lookup | Depends on use case | Only if explicitly requested |

**Ring behavior:** Deleted posts count toward "has_posted_today" (you used your slot) but the image is not displayed.

### Delivery URL Behavior

```
Scenario: Post is soft-deleted, user has cached image URL

1. URL is signed with 1-hour TTL
2. User can still load image until URL expires
3. After expiry, client requests new URLs
4. Server checks deleted_at, does not return URL
5. Cached CDN copy may persist (acceptable)

Result: Graceful expiry, no hard invalidation needed.
```

### Storage Reclamation (Optional, Not Required)

If storage costs become a concern:

```
Policy: Delete images for posts deleted > 90 days ago
Job: Weekly, off-peak hours
Query:
  SELECT image_path FROM daily_posts
  WHERE deleted_at IS NOT NULL
    AND deleted_at < NOW() - INTERVAL '90 days'

Safety: This is a cost optimization, not a correctness requirement.
```

---

## 6. Security: Preventing Abuse

### Preventing Re-uploads

**Threat:** User uploads image, then tries to upload again (replace)

**Mitigations:**

1. **Signed URL is path-specific:**
   - URL is only valid for `{user_id}/{post_id}.{ext}`
   - post_id is server-generated, used once
   - Same post_id cannot get a new upload URL

2. **No UPDATE policy:**
   - Even if user had the path, RLS blocks overwrites

3. **Confirm step validates:**
   - Before creating daily_posts, check object exists
   - If daily_posts already exists for post_id, reject

### Preventing Image Swapping

**Threat:** User uploads image A, gets URL, uploads image B to same path

**Mitigations:**

1. **Signed URL is single-use:**
   - PUT succeeds once, then path is occupied
   - Second PUT fails (object exists, no overwrite)

2. **Content-Type locked:**
   - Signed URL specifies Content-Type
   - Mismatched type rejected by Storage

3. **No delete + re-upload:**
   - User cannot delete from storage
   - Cannot "clear" path for new upload

### Preventing URL Guessing

**Threat:** User guesses another user's image path

**Mitigations:**

1. **UUIDs are unguessable:**
   - user_id: 128 bits
   - post_id: 128 bits
   - Combined: 2^256 possible paths

2. **Storage is private:**
   - No public access, even with correct path
   - Requires valid Supabase auth token for origin fetch

3. **ImageKit URLs are signed:**
   - Guessing path isn't enough
   - Need valid signature (requires private key)

4. **Signature scope:**
   - Signature covers path + transforms
   - Cannot reuse signature for different path

### Rate Limiting

| Endpoint | Limit | Window | Rationale |
|----------|-------|--------|-----------|
| `request-upload-url` | 5 | 1 minute | Prevent URL farming |
| `confirm-upload` | 5 | 1 minute | Prevent spam |
| `fetch_circle_state` | 60 | 1 minute | Normal usage ~10/min |
| `fetch_archive` | 30 | 1 minute | Pagination expected |

**Implementation:** Edge Function rate limiting via Supabase or external (e.g., Upstash Redis).

---

## 7. Cost Control Strategies

### Transformation Limits

**Problem:** Unlimited transforms = unlimited origin fetches + CDN processing

**Solution:** Allowlist specific transform presets

```
Allowed transforms (ImageKit URL restriction):
- tr=w-200,h-200,fo-auto,c-at_max     (thumb)
- tr=w-600,h-800,fo-auto,c-at_max     (preview)
- tr=w-1200,h-1600,fo-auto,c-at_max,q-80  (full)

Any other transform combination: Rejected by ImageKit URL restriction
```

**Configuration:** ImageKit → Settings → URL Restrictions → Allowed Transformations

### Cache Strategy

| Layer | TTL | Invalidation |
|-------|-----|--------------|
| ImageKit CDN | 1 year | Never (immutable paths) |
| Browser | 1 year | Never |
| iOS URLCache | System default | App-managed |

**Cost impact:**
- First fetch: Origin + transform cost
- Subsequent: $0 (served from CDN edge)
- High cache hit rate expected (same images viewed repeatedly)

### Egress Minimization

**Supabase → ImageKit (Origin Fetch)**

| Strategy | Implementation |
|----------|----------------|
| Cache everything | ImageKit caches origin response for 1 year |
| Lazy origin fetch | ImageKit only fetches on first request |
| No redundant variants | Limit to 3 transform presets |

**ImageKit → Client (CDN Egress)**

| Strategy | Implementation |
|----------|----------------|
| Appropriate sizing | Use `thumb` (200px) for grids, not `full` |
| WebP delivery | ImageKit auto-converts (smaller than JPEG) |
| Quality optimization | `q-80` for full size |
| HTTP/2 | Multiplexed requests for grid loading |

### Cost Estimation Framework

```
Variables:
- MAU: Monthly active users
- Posts/user/day: ~1 (by design)
- Views/post: ~5-10 (small circles)
- Circle size: 3-8 people

Monthly estimates (per 1000 MAU):
- New images: 1000 users × 30 days = 30,000 images
- Storage: 30,000 × 2MB avg = 60 GB/month (cumulative)
- Transforms: 3 presets × 30,000 = 90,000 transforms
- Origin fetches: 90,000 (first access per transform)
- CDN requests: 30,000 × 5 views × 3 sizes = 450,000/month

ImageKit pricing (as of 2024):
- Free tier: 20GB bandwidth/month
- Paid: ~$0.04/GB after free tier

Supabase Storage pricing:
- 1GB included
- $0.021/GB after
```

### Optimization Checklist

| Optimization | Impact | Implemented By |
|--------------|--------|----------------|
| Limit transform presets | High | ImageKit config |
| Aggressive caching | High | ImageKit default + headers |
| WebP auto-format | Medium | ImageKit auto |
| Quality reduction (q-80) | Medium | URL parameter |
| Lazy loading (client) | Medium | iOS implementation |
| Thumbnail-first grid | Medium | Client fetch strategy |
| Prefetch on scroll | Low | iOS implementation |

---

## Summary: Security Properties

| Property | Guarantee | Mechanism |
|----------|-----------|-----------|
| Auth required for upload | User must be authenticated | Edge Function validates JWT |
| Auth required for delivery | URLs are signed | ImageKit signature |
| No overwrites | Images are immutable | RLS + signed URL scope |
| No deletes | Images persist | No DELETE policy |
| No path guessing | UUIDs unguessable | 256-bit entropy |
| No transform abuse | Preset allowlist | ImageKit URL restriction |
| No repost after delete | Slot remains occupied | DB constraint unchanged |

---

## Summary: Cost Controls

| Control | Mechanism |
|---------|-----------|
| Transform limiting | 3 presets only |
| Aggressive caching | 1-year TTL, immutable |
| Appropriate sizing | Thumb for grids, full for detail |
| WebP conversion | ImageKit automatic |
| Quality optimization | q-80 for large images |
| No redundant fetches | Cache-first, lazy origin |

---

## Implementation Checklist

### Supabase

- [ ] Create `posts` bucket (private, 10MB limit)
- [ ] Apply RLS policies (INSERT, SELECT only)
- [ ] Configure allowed MIME types

### Edge Functions

- [ ] `request-upload-url`: Generate signed PUT URLs
- [ ] `confirm-upload`: Verify + create daily_posts record
- [ ] Update `post-fit` to use two-step flow

### ImageKit

- [ ] Configure Supabase as private origin
- [ ] Set up URL signing with private key
- [ ] Configure URL restrictions (allowed transforms)
- [ ] Enable WebP auto-format
- [ ] Set cache headers (immutable)

### Database

- [ ] Add `image_path` validation to `post_fit_internal`
- [ ] Add delivery URL generation function (optional, can be in Edge Function)

---

## Open Questions

1. **Orphan cleanup:** Should we run a weekly job to delete unconfirmed uploads?
   - Recommendation: Not initially. Monitor storage growth first.

2. **HEIC handling:** Should ImageKit convert HEIC to JPEG on delivery?
   - Recommendation: Yes, for web compatibility. iOS native can handle HEIC.

3. **Backup strategy:** Should images be replicated to another region?
   - Recommendation: Not initially. Supabase Storage is the source of truth.

These are operational decisions, not security or product decisions.
