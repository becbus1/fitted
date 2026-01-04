// =============================================================================
// FITTED: request-upload-url Edge Function
// =============================================================================
//
// Generates a signed URL for direct image upload to Supabase Storage.
// Called BEFORE the user captures their photo.
//
// FLOW:
// 1. Client calls this function with circle_id and timezone
// 2. This function validates eligibility and returns signed PUT URL
// 3. Client captures photo and PUTs directly to Storage
// 4. Client calls post-fit to create the database record
//
// INVARIANTS ENFORCED:
// 1. User is authenticated
// 2. User is active member of circle
// 3. User hasn't already posted today (pre-check, not authoritative)
// 4. Post ID is server-generated (prevents client-chosen paths)
// 5. Upload URL is scoped to exact path (prevents path traversal)
//
// WHY SEPARATE FROM post-fit:
// - Fail fast before photo capture (save user time)
// - Pre-validate eligibility
// - Generate post_id server-side (immutability)
// - Limit exposure window of signed URL
//
// IMPLEMENTATION NOTES:
// - NO Supabase SDK - uses fetch() for all API calls
// - Server generates post_id (client cannot choose)
// - Upload URL scoped to exact path with short TTL
//
// =============================================================================

import {
  RequestUploadUrlRequest,
  RequestUploadUrlResponse,
  CONTENT_TYPE_TO_EXT,
  STORAGE_BUCKET,
  UPLOAD_URL_TTL_SECONDS,
} from "../_shared/types.ts";

import {
  corsHeaders,
  errorResponse,
  jsonResponse,
  isValidUUID,
  calculateToday,
  verifyAuth,
  postgrest,
  createSignedUploadUrl,
} from "../_shared/utils.ts";

// =============================================================================
// MAIN HANDLER
// =============================================================================

Deno.serve(async (req: Request): Promise<Response> => {
  // ===========================================================================
  // CORS PREFLIGHT
  // ===========================================================================

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  // ===========================================================================
  // METHOD VALIDATION
  // ===========================================================================

  if (req.method !== "POST") {
    return errorResponse("INVALID_INPUT", "Method not allowed", 405);
  }

  try {
    // =========================================================================
    // STEP 1: AUTHENTICATE USER
    // =========================================================================
    // INVARIANT: Only authenticated users can request upload URLs
    // WHY: Prevents anonymous uploads, ties upload to user identity

    const authResult = await verifyAuth(req.headers.get("Authorization"));
    if ("error" in authResult) {
      return authResult.error;
    }
    const userId = authResult.userId;

    // =========================================================================
    // STEP 2: PARSE AND VALIDATE INPUT
    // =========================================================================

    let body: RequestUploadUrlRequest;
    try {
      body = await req.json();
    } catch {
      return errorResponse("INVALID_INPUT", "Invalid JSON body");
    }

    const { circle_id, timezone, content_type } = body;

    // Validate circle_id
    if (!circle_id || !isValidUUID(circle_id)) {
      return errorResponse("INVALID_INPUT", "Invalid or missing circle_id");
    }

    // Validate timezone
    if (!timezone || typeof timezone !== "string") {
      return errorResponse("INVALID_INPUT", "Invalid or missing timezone");
    }

    // Validate content_type
    if (!content_type || !CONTENT_TYPE_TO_EXT[content_type]) {
      return errorResponse(
        "INVALID_INPUT",
        "Invalid content_type. Must be image/jpeg, image/heic, or image/png"
      );
    }

    // =========================================================================
    // STEP 3: CALCULATE TODAY IN USER'S TIMEZONE
    // =========================================================================
    // WHY: Eligibility check uses the same date calculation as post_fit_internal
    // CONSISTENCY: Both functions use the same timezone → date logic

    const today = calculateToday(timezone);

    // =========================================================================
    // STEP 4: VALIDATE CIRCLE EXISTS
    // =========================================================================
    // INVARIANT: Circle must exist and not be deleted
    // WHY HERE: Fail fast before generating URLs

    const { data: circles, error: circleError } = await postgrest<
      Array<{ id: string; deleted_at: string | null }>
    >(`/circles?id=eq.${circle_id}&select=id,deleted_at`);

    if (circleError) {
      console.error("Error checking circle:", circleError);
      return errorResponse("SERVER_ERROR", "Failed to check circle");
    }

    if (!circles || circles.length === 0) {
      return errorResponse("CIRCLE_NOT_FOUND", "Circle not found");
    }

    const circle = circles[0];
    if (circle.deleted_at) {
      return errorResponse("CIRCLE_NOT_FOUND", "Circle has been deleted");
    }

    // =========================================================================
    // STEP 5: VALIDATE CIRCLE MEMBERSHIP
    // =========================================================================
    // INVARIANT: Only circle members can get upload URLs
    // WHY HERE: Fail fast before generating URLs

    const { data: memberships, error: memberError } = await postgrest<
      Array<{ id: string }>
    >(
      `/circle_memberships?user_id=eq.${userId}&circle_id=eq.${circle_id}&left_at=is.null&select=id`
    );

    if (memberError) {
      console.error("Error checking membership:", memberError);
      return errorResponse("SERVER_ERROR", "Failed to check membership");
    }

    if (!memberships || memberships.length === 0) {
      return errorResponse("NOT_MEMBER", "User is not a member of this circle");
    }

    // =========================================================================
    // STEP 6: CHECK POSTING ELIGIBILITY (PRE-CHECK)
    // =========================================================================
    // INVARIANT: One post per (user, circle, day)
    // WHY HERE: Fail fast before photo capture
    //
    // NOTE: This is a PRE-CHECK, not authoritative.
    // The DB constraint in post_fit_internal is the final authority.
    // Race conditions are handled there.

    const { data: existingPosts, error: postError } = await postgrest<
      Array<{ id: string }>
    >(
      `/daily_posts?user_id=eq.${userId}&circle_id=eq.${circle_id}&posted_date=eq.${today}&select=id`
    );

    if (postError) {
      console.error("Error checking existing post:", postError);
      return errorResponse("SERVER_ERROR", "Failed to check posting eligibility");
    }

    if (existingPosts && existingPosts.length > 0) {
      // User already posted today (including deleted posts - unique constraint includes all)
      return errorResponse("ALREADY_POSTED", "Already posted to this circle today");
    }

    // =========================================================================
    // STEP 7: GENERATE POST ID
    // =========================================================================
    // INVARIANT: Post ID is server-generated
    // WHY: Client cannot choose arbitrary paths
    // SECURITY: Prevents path traversal, ensures uniqueness

    const postId = crypto.randomUUID();

    // =========================================================================
    // STEP 8: CONSTRUCT IMAGE PATH
    // =========================================================================
    // FORMAT: {user_id}/{post_id}.{ext}
    //
    // SECURITY PROPERTIES:
    // - user_id prefix: RLS restricts uploads to own folder
    // - post_id: Server-generated, unique
    // - extension: Derived from declared content_type

    const ext = CONTENT_TYPE_TO_EXT[content_type];
    const imagePath = `${userId}/${postId}.${ext}`;

    // =========================================================================
    // STEP 9: GENERATE SIGNED UPLOAD URL
    // =========================================================================
    // SCOPE: Exact path only (no wildcards)
    // METHOD: PUT only
    // TTL: 5 minutes
    //
    // SECURITY: URL is only valid for this exact path.
    // Client cannot use it to upload to a different location.

    const signedUrlResult = await createSignedUploadUrl(STORAGE_BUCKET, imagePath);

    if (!signedUrlResult) {
      console.error("Error creating signed URL");
      return errorResponse("SERVER_ERROR", "Failed to generate upload URL");
    }

    // =========================================================================
    // STEP 10: RETURN RESPONSE
    // =========================================================================

    const expiresAt = new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000);

    const response: RequestUploadUrlResponse = {
      upload_url: signedUrlResult.signedUrl,
      post_id: postId,
      expires_at: expiresAt.toISOString(),
      image_path: imagePath,
    };

    return jsonResponse(response, 200);
  } catch (error) {
    console.error("Unexpected error in request-upload-url:", error);
    return errorResponse("SERVER_ERROR", "An unexpected error occurred");
  }
});
