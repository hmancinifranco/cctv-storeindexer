# Frontend

**Last reviewed:** 2026-10-22

React + TypeScript + Material UI single-page app (private S3 + CloudFront OAC).

Built in Phase 6:
- T6.1 — 2–3 distinct mockups, one selected as the visual spec (before coding).
- T6.2 — SPA: Cognito login, search, results table (server-side pagination),
  download action, and all state renderings (loading/empty/invalid-metadata/
  ready/denied/error). Centralized MUI theme; tests use accessible roles/labels.
- T6.3 — delivery via CloudFront + WAF + OAC.

Scaffolding (Vite) and dependencies are added at the start of T6.2 to avoid
committing an unused `node_modules` footprint during planning.
