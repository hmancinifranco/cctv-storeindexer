/**
 * Cognito hosted-UI authentication (OAuth 2.0 Authorization Code + PKCE).
 * No client secret (public SPA client). The ID token is kept in memory /
 * sessionStorage for the session; login/logout redirect through the hosted UI.
 *
 * Config comes from Vite env (VITE_*), set at build time from the deploy
 * outputs. For local dev, VITE_DEV_ID_TOKEN short-circuits the flow.
 */

const HOSTED_UI = import.meta.env.VITE_HOSTED_UI_DOMAIN ?? "";
const CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID ?? "";
const REDIRECT_URI = import.meta.env.VITE_REDIRECT_URI ?? window.location.origin + "/";
// Dev token short-circuit is ONLY honored on the Vite dev server. In a
// production build (import.meta.env.DEV === false) it is always empty, so a
// stray VITE_DEV_ID_TOKEN in .env.local can never bake a session into the
// shipped bundle.
const DEV_TOKEN = import.meta.env.DEV ? (import.meta.env.VITE_DEV_ID_TOKEN ?? "") : "";

const TOKEN_KEY = "cctv.idToken";
const VERIFIER_KEY = "cctv.pkceVerifier";

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256(input: string): Promise<Uint8Array> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return new Uint8Array(digest);
}

function randomVerifier(): string {
  const bytes = new Uint8Array(64);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}

/** Current ID token if authenticated, else null. */
export function getIdToken(): string | null {
  if (DEV_TOKEN) return DEV_TOKEN;
  return sessionStorage.getItem(TOKEN_KEY);
}

export function isConfigured(): boolean {
  return Boolean(DEV_TOKEN) || Boolean(HOSTED_UI && CLIENT_ID);
}

/** Redirect to the Cognito hosted UI to log in (PKCE). */
export async function login(): Promise<void> {
  const verifier = randomVerifier();
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  const challenge = base64url(await sha256(verifier));
  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: "code",
    scope: "openid email profile",
    redirect_uri: REDIRECT_URI,
    code_challenge_method: "S256",
    code_challenge: challenge,
  });
  window.location.assign(`${HOSTED_UI}/oauth2/authorize?${params}`);
}

export function logout(): void {
  sessionStorage.removeItem(TOKEN_KEY);
  const params = new URLSearchParams({ client_id: CLIENT_ID, logout_uri: REDIRECT_URI });
  window.location.assign(`${HOSTED_UI}/logout?${params}`);
}

/**
 * If the URL carries an OAuth ?code=, exchange it for tokens (PKCE) and store
 * the ID token. Returns true if a token was obtained. Call once on app load.
 */
export async function completeLoginIfRedirected(): Promise<boolean> {
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");
  if (!code) return Boolean(getIdToken());

  const verifier = sessionStorage.getItem(VERIFIER_KEY) ?? "";
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: CLIENT_ID,
    code,
    redirect_uri: REDIRECT_URI,
    code_verifier: verifier,
  });
  const res = await fetch(`${HOSTED_UI}/oauth2/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) return false;
  const tokens = await res.json();
  if (tokens.id_token) sessionStorage.setItem(TOKEN_KEY, tokens.id_token);
  // Clean the ?code= from the URL bar.
  url.searchParams.delete("code");
  url.searchParams.delete("state");
  window.history.replaceState({}, "", url.toString());
  return Boolean(tokens.id_token);
}
