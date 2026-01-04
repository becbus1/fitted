// =============================================================================
// FITTED: Shared Utilities for Edge Functions
// =============================================================================
//
// Common helper functions used across Edge Functions.
// Uses fetch() for all Supabase API calls - NO SDK.
//
// =============================================================================

import {
  ErrorCode,
  ErrorResponse,
  ERROR_STATUS_MAP,
  SupabaseAuthResponse,
} from "./types.ts";

// =============================================================================
// CONFIGURATION
// =============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// =============================================================================
// CORS
// =============================================================================

/**
 * Standard CORS headers for iOS client
 */
export function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, x-client-info, apikey",
  };
}

// =============================================================================
// RESPONSE HELPERS
// =============================================================================

/**
 * Create standardized error response
 */
export function errorResponse(
  code: ErrorCode,
  message?: string,
  statusOverride?: number
): Response {
  const status = statusOverride ?? ERROR_STATUS_MAP[code] ?? 500;
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

/**
 * Create success JSON response
 */
export function jsonResponse<T>(data: T, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders(),
      "Content-Type": "application/json",
    },
  });
}

// =============================================================================
// VALIDATION
// =============================================================================

/**
 * Validate UUID format
 */
export function isValidUUID(str: string): boolean {
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(str);
}

/**
 * Calculate today's date in user's timezone
 * Returns YYYY-MM-DD format
 */
export function calculateToday(timezone: string): string {
  try {
    const formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    });
    return formatter.format(new Date());
  } catch {
    // Invalid timezone, fall back to UTC
    return new Date().toISOString().split("T")[0];
  }
}

// =============================================================================
// SUPABASE AUTH (via fetch)
// =============================================================================

/**
 * Verify JWT and extract user ID
 * Uses Supabase Auth API directly via fetch
 *
 * INVARIANT: Only authenticated users can proceed
 */
export async function verifyAuth(
  authHeader: string | null
): Promise<{ userId: string } | { error: Response }> {
  if (!authHeader?.startsWith("Bearer ")) {
    return { error: errorResponse("AUTH_REQUIRED", "Missing authorization header") };
  }

  const token = authHeader.replace("Bearer ", "");

  // Call Supabase Auth API to verify token and get user
  // Endpoint: GET /auth/v1/user
  const response = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: SUPABASE_ANON_KEY,
    },
  });

  if (!response.ok) {
    return { error: errorResponse("AUTH_REQUIRED", "Invalid or expired token") };
  }

  const user: SupabaseAuthResponse = await response.json();

  if (!user?.id) {
    return { error: errorResponse("AUTH_REQUIRED", "Invalid user data") };
  }

  return { userId: user.id };
}

// =============================================================================
// SUPABASE POSTGREST (via fetch)
// =============================================================================

interface PostgRESTOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  body?: unknown;
  headers?: Record<string, string>;
  // If true, use service role key (bypasses RLS)
  useServiceRole?: boolean;
}

/**
 * Make a PostgREST query
 * Uses fetch() directly - NO SDK
 */
export async function postgrest<T>(
  path: string,
  options: PostgRESTOptions = {}
): Promise<{ data: T | null; error: string | null }> {
  const { method = "GET", body, headers = {}, useServiceRole = true } = options;

  const apiKey = useServiceRole ? SUPABASE_SERVICE_ROLE_KEY : SUPABASE_ANON_KEY;

  const response = await fetch(`${SUPABASE_URL}/rest/v1${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      apikey: apiKey,
      Authorization: `Bearer ${apiKey}`,
      // Prefer: return=representation for POST/PATCH to get inserted/updated rows
      ...(method !== "GET" && method !== "DELETE"
        ? { Prefer: "return=representation" }
        : {}),
      ...headers,
    },
    ...(body && { body: JSON.stringify(body) }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    return { data: null, error: errorText };
  }

  // Handle empty responses (204 No Content)
  if (response.status === 204) {
    return { data: null, error: null };
  }

  const data = await response.json();
  return { data, error: null };
}

/**
 * Call a Postgres RPC function
 */
export async function rpc<T>(
  functionName: string,
  params: Record<string, unknown>
): Promise<{ data: T | null; error: string | null }> {
  return postgrest<T>(`/rpc/${functionName}`, {
    method: "POST",
    body: params,
    useServiceRole: true,
  });
}

// =============================================================================
// SUPABASE STORAGE (via fetch)
// =============================================================================

/**
 * List objects in a storage bucket folder
 */
export async function storageList(
  bucket: string,
  folder: string,
  search?: string
): Promise<{ data: Array<{ name: string }> | null; error: string | null }> {
  const params = new URLSearchParams();
  if (search) {
    params.set("search", search);
  }
  params.set("limit", "10");

  const response = await fetch(
    `${SUPABASE_URL}/storage/v1/object/list/${bucket}?${params}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify({ prefix: folder }),
    }
  );

  if (!response.ok) {
    const errorText = await response.text();
    return { data: null, error: errorText };
  }

  const data = await response.json();
  return { data, error: null };
}

/**
 * Check if an object exists in storage
 */
export async function storageObjectExists(
  bucket: string,
  path: string
): Promise<boolean> {
  // Use HEAD request to check existence without downloading
  const response = await fetch(
    `${SUPABASE_URL}/storage/v1/object/${bucket}/${path}`,
    {
      method: "HEAD",
      headers: {
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      },
    }
  );

  return response.ok;
}

/**
 * Create a signed upload URL for a specific path
 *
 * SECURITY: URL is scoped to exact path, prevents path traversal
 */
export async function createSignedUploadUrl(
  bucket: string,
  path: string
): Promise<{ signedUrl: string; token: string } | null> {
  const response = await fetch(
    `${SUPABASE_URL}/storage/v1/object/upload/sign/${bucket}/${path}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify({
        // expiresIn is in seconds
        expiresIn: 300, // 5 minutes
      }),
    }
  );

  if (!response.ok) {
    return null;
  }

  const data = await response.json();

  // The signed URL is constructed from the response
  // Response contains: { url: string } or { signedURL: string }
  const signedUrl = data.signedURL || data.url;

  if (!signedUrl) {
    return null;
  }

  return {
    signedUrl: `${SUPABASE_URL}/storage/v1${signedUrl}`,
    token: data.token || "",
  };
}

// =============================================================================
// RPC ERROR PARSING
// =============================================================================

/**
 * Parse RPC error message to extract error code
 *
 * RPC raises exceptions like: RAISE EXCEPTION 'ALREADY_POSTED'
 * PostgREST wraps these in error objects.
 */
export function parseRpcError(errorText: string): ErrorCode {
  const knownCodes: ErrorCode[] = [
    "AUTH_REQUIRED",
    "INVALID_INPUT",
    "CIRCLE_NOT_FOUND",
    "NOT_MEMBER",
    "ALREADY_POSTED",
  ];

  for (const code of knownCodes) {
    if (errorText.includes(code)) {
      return code;
    }
  }

  return "SERVER_ERROR";
}
