// =============================================================================
// FITTED: post-fit Edge Function
// =============================================================================
//
// Creates a daily post after image upload has been confirmed.
//
// FLOW:
// 1. Client requests signed upload URL (request-upload-url)
// 2. Client PUTs image directly to Storage
// 3. Client calls THIS function to create the post record
//
// INVARIANTS ENFORCED:
// 1. User is authenticated (JWT validation)
// 2. User is active member of circle (RPC validates)
// 3. One post per (user, circle, day) (RPC + DB constraint)
// 4. Image exists at expected path (Storage check)
// 5. Image path matches user ID (prevents path injection)
// 6. Post ID in path is unused (prevents replay)
//
// IMPLEMENTATION NOTES:
// - NO Supabase SDK - uses fetch() for all API calls
// - Calls post_fit_internal RPC for atomic DB operations
// - Generates signed ImageKit URL for delivery
//
// =============================================================================

import {
  PostFitRequest,
  PostFitResponse,
  PostFitInternalResult,
  STORAGE_BUCKET,
  IMAGE_URL_TTL_SECONDS,
} from "../_shared/types.ts";

import {
  corsHeaders,
  errorResponse,
  jsonResponse,
  isValidUUID,
  verifyAuth,
  postgrest,
  rpc,
  storageObjectExists,
  parseRpcError,
} from "../_shared/utils.ts";

// =============================================================================
// CONFIGURATION
// =============================================================================

const IMAGEKIT_URL_ENDPOINT = Deno.env.get("IMAGEKIT_URL_ENDPOINT") || "";
const IMAGEKIT_PRIVATE_KEY = Deno.env.get("IMAGEKIT_PRIVATE_KEY") || "";

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
    // INVARIANT: Only authenticated users can post
    // WHY HERE: Fail fast before any other processing

    const authResult = await verifyAuth(req.headers.get("Authorization"));
    if ("error" in authResult) {
      return authResult.error;
    }
    const userId = authResult.userId;

    // =========================================================================
    // STEP 2: PARSE AND VALIDATE INPUT
    // =========================================================================
    // INVARIANT: All required fields present and well-formed
    // WHY HERE: Fail fast before expensive operations

    let body: PostFitRequest;
    try {
      body = await req.json();
    } catch {
      return errorResponse("INVALID_INPUT", "Invalid JSON body");
    }

    const { circle_id, timezone, post_id, image_width, image_height } = body;

    // Validate circle_id
    if (!circle_id || !isValidUUID(circle_id)) {
      return errorResponse("INVALID_INPUT", "Invalid or missing circle_id");
    }

    // Validate timezone
    if (!timezone || typeof timezone !== "string") {
      return errorResponse("INVALID_INPUT", "Invalid or missing timezone");
    }

    // Validate post_id
    if (!post_id || !isValidUUID(post_id)) {
      return errorResponse("INVALID_INPUT", "Invalid or missing post_id");
    }

    // =========================================================================
    // STEP 3: CHECK FOR REPLAY ATTACK
    // =========================================================================
    // INVARIANT: Post ID can only be used once
    // WHY HERE: Prevent client from reusing a post_id to overwrite/replay
    //
    // ATTACK SCENARIO:
    // 1. User posts successfully with post_id=ABC
    // 2. User deletes the post (soft delete)
    // 3. User tries to call post-fit again with post_id=ABC
    // 4. Without this check, they could create a new post pointing to old image

    const { data: existingPosts, error: checkError } = await postgrest<
      Array<{ id: string }>
    >(`/daily_posts?id=eq.${post_id}&select=id`);

    if (checkError) {
      console.error("Error checking existing post:", checkError);
      return errorResponse("SERVER_ERROR", "Failed to check post status");
    }

    if (existingPosts && existingPosts.length > 0) {
      // Post ID already exists (even if deleted) - this is a replay
      return errorResponse("POST_ID_REUSED", "Post ID has already been used");
    }

    // =========================================================================
    // STEP 4: FIND AND VALIDATE IMAGE PATH
    // =========================================================================
    // INVARIANT: Image path must match user ID
    // WHY HERE: Prevent user from claiming another user's image
    //
    // ATTACK SCENARIO:
    // 1. Attacker knows victim's user_id and a valid post_id
    // 2. Attacker tries to post with victim's image path
    // 3. This check ensures the path starts with the authenticated user's ID

    const imagePath = await findImagePath(userId, post_id);

    if (!imagePath) {
      return errorResponse("IMAGE_NOT_FOUND", "Image not found at expected path");
    }

    // Verify path ownership (defense in depth)
    // Expected: {user_id}/{post_id}.{ext}
    if (!imagePath.startsWith(`${userId}/`)) {
      console.error(`Path mismatch: expected ${userId}/*, got ${imagePath}`);
      return errorResponse("IMAGE_PATH_MISMATCH", "Image path does not match user");
    }

    // =========================================================================
    // STEP 5: CALL post_fit_internal RPC
    // =========================================================================
    // INVARIANT: Atomic post creation with all validations
    // WHY RPC: The RPC handles membership check, eligibility check, and
    //          atomic insert with constraint handling for race conditions
    //
    // WHAT RPC VALIDATES:
    // - User is active member of circle (NOT_MEMBER)
    // - User hasn't posted today (ALREADY_POSTED)
    // - Unique constraint (ALREADY_POSTED on race)

    const { data: rpcResult, error: rpcError } = await rpc<PostFitInternalResult[]>(
      "post_fit_internal",
      {
        p_user_id: userId,
        p_circle_id: circle_id,
        p_timezone: timezone,
        p_image_path: imagePath,
        p_image_width: image_width ?? null,
        p_image_height: image_height ?? null,
      }
    );

    if (rpcError) {
      // Map RPC exceptions to HTTP responses
      const errorCode = parseRpcError(rpcError);
      return errorResponse(errorCode, rpcError);
    }

    // RPC returns array, get first (only) row
    const post = Array.isArray(rpcResult) ? rpcResult[0] : rpcResult;

    if (!post) {
      console.error("RPC returned no data");
      return errorResponse("SERVER_ERROR", "Post creation returned no data");
    }

    // =========================================================================
    // STEP 6: GENERATE SIGNED DELIVERY URL
    // =========================================================================
    // WHY: Storage is private; client needs signed URL to display image
    // TTL: 1 hour; client refreshes on app foreground

    const imageUrl = await generateSignedImageUrl(imagePath, {
      width: 600,
      height: 800,
    });

    // =========================================================================
    // STEP 7: RETURN SUCCESS RESPONSE
    // =========================================================================

    const response: PostFitResponse = {
      post: {
        id: post.id,
        circle_id: post.circle_id,
        posted_date: post.posted_date,
        posted_at: post.posted_at,
        image_url: imageUrl,
      },
    };

    return jsonResponse(response, 201);
  } catch (error) {
    // =========================================================================
    // UNEXPECTED ERROR HANDLER
    // =========================================================================
    console.error("Unexpected error in post-fit:", error);
    return errorResponse("SERVER_ERROR", "An unexpected error occurred");
  }
});

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/**
 * Find image in storage by checking known extensions
 *
 * WHY: Client uploads with content-type, extension is derived from that.
 * We check common extensions in order of likelihood.
 *
 * SECURITY: We only look in the user's folder, and only for the specific post_id.
 */
async function findImagePath(
  userId: string,
  postId: string
): Promise<string | null> {
  const extensions = ["jpg", "jpeg", "heic", "png"];

  for (const ext of extensions) {
    const path = `${userId}/${postId}.${ext}`;
    const exists = await storageObjectExists(STORAGE_BUCKET, path);
    if (exists) {
      return path;
    }
  }

  return null;
}

/**
 * Generate signed ImageKit URL for image delivery
 *
 * Uses HMAC-SHA256 signature for URL authentication.
 * Includes transformation parameters for responsive sizing.
 */
async function generateSignedImageUrl(
  imagePath: string,
  options: { width: number; height: number }
): Promise<string> {
  const expiryTimestamp = Math.floor(Date.now() / 1000) + IMAGE_URL_TTL_SECONDS;

  // Transformation string for ImageKit
  const transform = `tr=w-${options.width},h-${options.height},fo-auto,c-at_max`;

  // Path for signature (without query params)
  const urlPath = `/posts/${imagePath}`;

  // If ImageKit is not configured, return a placeholder URL
  // (allows testing without ImageKit setup)
  if (!IMAGEKIT_URL_ENDPOINT || !IMAGEKIT_PRIVATE_KEY) {
    console.warn("ImageKit not configured, returning unsigned URL");
    return `${IMAGEKIT_URL_ENDPOINT || "https://ik.imagekit.io/fitted"}${urlPath}?${transform}`;
  }

  // Generate signature using Web Crypto API
  const signature = await generateImageKitSignature(urlPath, expiryTimestamp);

  return `${IMAGEKIT_URL_ENDPOINT}${urlPath}?${transform}&ik-t=${expiryTimestamp}&ik-s=${signature}`;
}

/**
 * Generate ImageKit URL signature using HMAC-SHA256
 *
 * SECURITY: This prevents URL tampering and guessing.
 * Signature covers: path + expiry timestamp
 *
 * ImageKit signature algorithm:
 * signature = HMAC-SHA256(privateKey, url + timestamp)
 */
async function generateImageKitSignature(
  urlPath: string,
  expiry: number
): Promise<string> {
  const encoder = new TextEncoder();

  // Import the private key for HMAC
  const keyData = encoder.encode(IMAGEKIT_PRIVATE_KEY);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  // Sign the URL path + expiry timestamp
  const dataToSign = encoder.encode(`${urlPath}${expiry}`);
  const signatureBuffer = await crypto.subtle.sign("HMAC", cryptoKey, dataToSign);

  // Convert to hex string
  const signatureArray = new Uint8Array(signatureBuffer);
  return Array.from(signatureArray)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
