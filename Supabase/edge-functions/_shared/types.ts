// =============================================================================
// FITTED: Shared Types for Edge Functions
// =============================================================================
//
// Pure type definitions shared across Edge Functions.
// NO runtime behavior - types only.
//
// =============================================================================

// =============================================================================
// ERROR CODES
// =============================================================================

/**
 * Canonical error codes per api-contract.md
 * Client can switch on these for UI handling
 */
export type ErrorCode =
  | "AUTH_REQUIRED"        // 401: No valid JWT
  | "INVALID_INPUT"        // 400: Missing or malformed fields
  | "CIRCLE_NOT_FOUND"     // 404: Circle doesn't exist or deleted
  | "NOT_MEMBER"           // 403: User not in circle
  | "ALREADY_POSTED"       // 409: Already posted today
  | "IMAGE_NOT_FOUND"      // 400: Image not at expected path
  | "IMAGE_PATH_MISMATCH"  // 403: Path doesn't match user
  | "POST_ID_REUSED"       // 409: Post ID already exists (replay attack)
  | "SERVER_ERROR";        // 500: Unexpected failure

/**
 * Map error codes to HTTP status codes
 */
export const ERROR_STATUS_MAP: Record<ErrorCode, number> = {
  AUTH_REQUIRED: 401,
  INVALID_INPUT: 400,
  CIRCLE_NOT_FOUND: 404,
  NOT_MEMBER: 403,
  ALREADY_POSTED: 409,
  IMAGE_NOT_FOUND: 400,
  IMAGE_PATH_MISMATCH: 403,
  POST_ID_REUSED: 409,
  SERVER_ERROR: 500,
};

// =============================================================================
// REQUEST/RESPONSE TYPES
// =============================================================================

/**
 * Standard error response shape per api-contract.md
 */
export interface ErrorResponse {
  error: {
    code: ErrorCode;
    message?: string;
  };
}

/**
 * post-fit request payload
 */
export interface PostFitRequest {
  circle_id: string;
  timezone: string;
  post_id: string;
  image_width?: number;
  image_height?: number;
}

/**
 * post-fit success response
 */
export interface PostFitResponse {
  post: {
    id: string;
    circle_id: string;
    posted_date: string;
    posted_at: string;
    image_url: string;
  };
}

/**
 * request-upload-url request payload
 */
export interface RequestUploadUrlRequest {
  circle_id: string;
  timezone: string;
  content_type: "image/jpeg" | "image/heic" | "image/png";
}

/**
 * request-upload-url success response
 */
export interface RequestUploadUrlResponse {
  upload_url: string;
  post_id: string;
  expires_at: string;
  image_path: string;
}

// =============================================================================
// SUPABASE AUTH TYPES
// =============================================================================

/**
 * Supabase user object (subset of fields we use)
 */
export interface SupabaseUser {
  id: string;
  email?: string;
  created_at?: string;
}

/**
 * Supabase auth response
 */
export interface SupabaseAuthResponse {
  id: string;
  aud: string;
  role: string;
  email?: string;
}

// =============================================================================
// RPC TYPES
// =============================================================================

/**
 * post_fit_internal RPC response row
 */
export interface PostFitInternalResult {
  id: string;
  circle_id: string;
  posted_date: string;
  posted_at: string;
}

// =============================================================================
// CONFIGURATION
// =============================================================================

/** Allowed MIME types for uploads */
export const ALLOWED_CONTENT_TYPES = [
  "image/jpeg",
  "image/heic",
  "image/png",
] as const;

/** Map content types to file extensions */
export const CONTENT_TYPE_TO_EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/heic": "heic",
  "image/png": "png",
};

/** Storage bucket name */
export const STORAGE_BUCKET = "posts";

/** Upload URL TTL in seconds */
export const UPLOAD_URL_TTL_SECONDS = 300; // 5 minutes

/** Signed image delivery URL TTL in seconds */
export const IMAGE_URL_TTL_SECONDS = 3600; // 1 hour
