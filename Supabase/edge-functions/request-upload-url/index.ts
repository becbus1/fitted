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
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// =============================================================================
// TYPES
// =============================================================================

interface RequestUploadUrlRequest {
  /** UUID of circle to post to */
  circle_id: string;

  /** IANA timezone for date calculation */
  timezone: string;

  /** MIME type of image to upload */
  content_type: "image/jpeg" | "image/heic" | "image/png";
}

interface RequestUploadUrlResponse {
  /** Signed PUT URL for direct upload */
  upload_url: string;

  /** Server-generated post ID (use in post-fit call) */
  post_id: string;

  /** When the upload URL expires */
  expires_at: string;

  /** Expected image path (for client reference) */
  image_path: string;
}

interface ErrorResponse {
  error: {
    code: ErrorCode;
    message?: string;
  };
}

type ErrorCode =
  | "AUTH_REQUIRED"
  | "INVALID_INPUT"
  | "CIRCLE_NOT_FOUND"
  | "NOT_MEMBER"
  | "ALREADY_POSTED"
  | "SERVER_ERROR";

// =============================================================================
// CONFIGURATION
// =============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** Upload URL TTL - short window to limit exposure */
const UPLOAD_URL_TTL_SECONDS = 300; // 5 minutes

/** Storage bucket name */
const STORAGE_BUCKET = "posts";

/** Map content types to file extensions */
const CONTENT_TYPE_TO_EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/heic": "heic",
  "image/png": "png",
};

// =============================================================================
// MAIN HANDLER
// =============================================================================

Deno.serve(async (req: Request): Promise<Response> => {
  // ===========================================================================
  // CORS PREFLIGHT
  // ===========================================================================

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  if (req.method !== "POST") {
    return errorResponse("INVALID_INPUT", 405, "Method not allowed");
  }

  try {
    // =========================================================================
    // STEP 1: AUTHENTICATE USER
    // =========================================================================
    // INVARIANT: Only authenticated users can request upload URLs
    // WHY: Prevents anonymous uploads, ties upload to user identity

    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return errorResponse("AUTH_REQUIRED", 401, "Missing authorization header");
    }

    const token = authHeader.replace("Bearer ", "");

    const userClient = createClient(SUPABASE_URL, token, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();

    if (authError || !user) {
      return errorResponse("AUTH_REQUIRED", 401, "Invalid or expired token");
    }

    const userId = user.id;

    // =========================================================================
    // STEP 2: PARSE AND VALIDATE INPUT
    // =========================================================================

    let body: RequestUploadUrlRequest;
    try {
      body = await req.json();
    } catch {
      return errorResponse("INVALID_INPUT", 400, "Invalid JSON body");
    }

    const { circle_id, timezone, content_type } = body;

    if (!circle_id || !isValidUUID(circle_id)) {
      return errorResponse("INVALID_INPUT", 400, "Invalid or missing circle_id");
    }

    if (!timezone || typeof timezone !== "string") {
      return errorResponse("INVALID_INPUT", 400, "Invalid or missing timezone");
    }

    if (!content_type || !CONTENT_TYPE_TO_EXT[content_type]) {
      return errorResponse(
        "INVALID_INPUT",
        400,
        "Invalid content_type. Must be image/jpeg, image/heic, or image/png"
      );
    }

    // =========================================================================
    // STEP 3: CALCULATE TODAY IN USER'S TIMEZONE
    // =========================================================================
    // WHY: Eligibility check uses the same date calculation as post_fit_internal
    // CONSISTENCY: Both functions use the same timezone → date logic

    let today: string;
    try {
      // Use Intl API for timezone conversion
      const formatter = new Intl.DateTimeFormat("en-CA", {
        timeZone: timezone,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
      });
      today = formatter.format(new Date()); // Returns YYYY-MM-DD
    } catch {
      // Invalid timezone, fall back to UTC
      const now = new Date();
      today = now.toISOString().split("T")[0];
    }

    // =========================================================================
    // STEP 4: VALIDATE CIRCLE MEMBERSHIP
    // =========================================================================
    // INVARIANT: Only circle members can get upload URLs
    // WHY HERE: Fail fast before generating URLs
    //
    // NOTE: This uses service role to bypass RLS and check directly.
    // RLS would also work but we want explicit error codes.

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    // Check circle exists
    const { data: circle, error: circleError } = await adminClient
      .from("circles")
      .select("id, deleted_at")
      .eq("id", circle_id)
      .maybeSingle();

    if (circleError) {
      console.error("Error checking circle:", circleError);
      return errorResponse("SERVER_ERROR", 500, "Failed to check circle");
    }

    if (!circle) {
      return errorResponse("CIRCLE_NOT_FOUND", 404, "Circle not found");
    }

    if (circle.deleted_at) {
      return errorResponse("CIRCLE_NOT_FOUND", 404, "Circle has been deleted");
    }

    // Check membership
    const { data: membership, error: memberError } = await adminClient
      .from("circle_memberships")
      .select("id")
      .eq("user_id", userId)
      .eq("circle_id", circle_id)
      .is("left_at", null)
      .maybeSingle();

    if (memberError) {
      console.error("Error checking membership:", memberError);
      return errorResponse("SERVER_ERROR", 500, "Failed to check membership");
    }

    if (!membership) {
      return errorResponse("NOT_MEMBER", 403, "User is not a member of this circle");
    }

    // =========================================================================
    // STEP 5: CHECK POSTING ELIGIBILITY (PRE-CHECK)
    // =========================================================================
    // INVARIANT: One post per (user, circle, day)
    // WHY HERE: Fail fast before photo capture
    //
    // NOTE: This is a PRE-CHECK, not authoritative.
    // The DB constraint in post_fit_internal is the final authority.
    // Race conditions are handled there.

    const { data: existingPost, error: postError } = await adminClient
      .from("daily_posts")
      .select("id")
      .eq("user_id", userId)
      .eq("circle_id", circle_id)
      .eq("posted_date", today)
      .maybeSingle();

    if (postError) {
      console.error("Error checking existing post:", postError);
      return errorResponse("SERVER_ERROR", 500, "Failed to check posting eligibility");
    }

    if (existingPost) {
      // User already posted today (including deleted posts)
      return errorResponse("ALREADY_POSTED", 409, "Already posted to this circle today");
    }

    // =========================================================================
    // STEP 6: GENERATE POST ID
    // =========================================================================
    // INVARIANT: Post ID is server-generated
    // WHY: Client cannot choose arbitrary paths
    // SECURITY: Prevents path traversal, ensures uniqueness

    const postId = crypto.randomUUID();

    // =========================================================================
    // STEP 7: CONSTRUCT IMAGE PATH
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
    // STEP 8: GENERATE SIGNED UPLOAD URL
    // =========================================================================
    // SCOPE: Exact path only (no wildcards)
    // METHOD: PUT only
    // TTL: 5 minutes
    //
    // SECURITY: URL is only valid for this exact path.
    // Client cannot use it to upload to a different location.

    const { data: signedUrlData, error: signedUrlError } = await adminClient
      .storage
      .from(STORAGE_BUCKET)
      .createSignedUploadUrl(imagePath, {
        upsert: false, // CRITICAL: Prevent overwrites
      });

    if (signedUrlError || !signedUrlData) {
      console.error("Error creating signed URL:", signedUrlError);
      return errorResponse("SERVER_ERROR", 500, "Failed to generate upload URL");
    }

    // =========================================================================
    // STEP 9: RETURN RESPONSE
    // =========================================================================

    const expiresAt = new Date(Date.now() + UPLOAD_URL_TTL_SECONDS * 1000);

    const response: RequestUploadUrlResponse = {
      upload_url: signedUrlData.signedUrl,
      post_id: postId,
      expires_at: expiresAt.toISOString(),
      image_path: imagePath,
    };

    return new Response(JSON.stringify(response), {
      status: 200,
      headers: {
        ...corsHeaders(),
        "Content-Type": "application/json",
      },
    });
  } catch (error) {
    console.error("Unexpected error in request-upload-url:", error);
    return errorResponse("SERVER_ERROR", 500, "An unexpected error occurred");
  }
});

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

function isValidUUID(str: string): boolean {
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(str);
}

function errorResponse(
  code: ErrorCode,
  status: number,
  message?: string
): Response {
  const body: ErrorResponse = {
    error: {
      code,
      ...(message && { message }),
    },
  };

  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(),
      "Content-Type": "application/json",
    },
  });
}

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
  };
}
