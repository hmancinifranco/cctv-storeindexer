/**
 * API client for the search/download REST API (design §6).
 * Base URL and Cognito IDs come from Vite env (VITE_*), never hardcoded.
 */

export interface VideoItem {
  objectKey: string;
  cameraId: string | null;
  recordedAtUtc: string | null;
  recordedAtLocal: string | null;
  sizeBytes: number | null;
  catalogStatus: "OK" | "INVALID_METADATA" | string;
  storageClass: string | null;
  accessTier?: string | null;
  lifecycleState?: "AVAILABLE" | "ARCHIVED" | "RESTORE_PENDING" | "RESTORED" | "DELETED";
  restoreStatus?: "NOT_REQUIRED" | "NOT_REQUESTED" | "PENDING" | "RESTORED" | "EXPIRED";
  stateChangedAt?: string | null;
  storageClassChangedAt?: string | null;
  accessTierChangedAt?: string | null;
  archivedAt?: string | null;
  restoreRequestedAt?: string | null;
  restoredAt?: string | null;
  restoreExpiresAt?: string | null;
  restoreExpiredAt?: string | null;
  deleted?: boolean;
  deletedAt?: string | null;
  deletionReason?: string | null;
  stableId: string;
}

export interface SearchResponse {
  items: VideoItem[];
  cursor: string | null;
}

export interface SearchParams {
  date?: string;
  from?: string;
  to?: string;
  camera?: string;
  cursor?: string;
  limit?: number;
  includeDeleted?: boolean;
}

const API_BASE = import.meta.env.VITE_API_BASE ?? "";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

function authHeaders(idToken: string): HeadersInit {
  return { Authorization: idToken };
}

async function parse<T>(res: Response): Promise<T> {
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new ApiError(res.status, body.code ?? "ERROR", body.message ?? res.statusText);
  }
  return body as T;
}

export async function searchVideos(
  idToken: string,
  params: SearchParams,
): Promise<SearchResponse> {
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== "") qs.set(k, String(v));
  }
  const res = await fetch(`${API_BASE}/videos?${qs.toString()}`, {
    headers: authHeaders(idToken),
  });
  return parse<SearchResponse>(res);
}

export async function requestDownloadUrl(
  idToken: string,
  videoId: string,
): Promise<{ url: string; expiresInSeconds: number }> {
  const res = await fetch(`${API_BASE}/videos/${encodeURIComponent(videoId)}/download`, {
    method: "POST",
    headers: authHeaders(idToken),
  });
  return parse<{ url: string; expiresInSeconds: number }>(res);
}
