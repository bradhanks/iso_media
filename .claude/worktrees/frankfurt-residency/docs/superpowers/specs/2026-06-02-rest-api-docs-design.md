# REST API Docs — Published OpenAPI Reference (Spec 7) — Design

**Date:** 2026-06-02
**Status:** Approved (decisions locked via brainstorming) — pending implementation
**Nature:** Additive feature. Generate a code-derived OpenAPI 3.1 spec from the REST controllers and publish a branded, public API reference page. No change to existing API behavior.

## Why

Enterprise/developer adoption needs a real, accurate, browsable API reference. Hand-written docs drift; code-derived docs stay true. This makes the REST surface self-documenting and gives a public `/api/docs` page consumers can read.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Spec source | **OpenApiSpex** — code-derived OpenAPI 3.1 from controller annotations + schema modules (stays in sync; serves `/api/openapi.json`). Add the `open_api_spex` dep. |
| Renderer | **Redoc** — clean three-panel read-only reference, themed to the `paper` brand, served at `/api/docs`. |
| Scope | **All `/api` endpoints**: History (index/show/delete/mark-viewed/visibility/dismiss/address), Credit (credit-score), AND auth (users log-in/out/update-password, OAuth request/callback). |
| Access | **Public** docs page + public `/api/openapi.json` (standard for an API reference). |
| Validation | Spec/docs only this pass. **Do NOT enable `CastAndValidate` request enforcement** (it would change API behavior / could reject currently-accepted requests). Noted as a future option. |

## Endpoints to document

From `lib/perfect_paper_web/router.ex` (`/api`):
- **History** (`Api.HistoryController`): `GET /api/history`, `GET /api/history/:id`, `DELETE /api/history/:id`, `POST /api/history/:id/mark-viewed`, `PATCH /api/history/:id/visibility`, `PATCH /api/history/:session_id/comments/:comment_id/dismiss`, `PATCH /api/history/:session_id/comments/:comment_id/address`.
- **Credit** (`Api.CreditController`): `GET /api/credit-score`.
- **Auth**: `POST /api/users/log-in`, `DELETE /api/users/log-out`, `POST /api/users/update-password`, `GET /api/auth/:provider`, `GET /api/auth/:provider/callback`. (Cookie/redirect flows are partially modeled — documented with notes where OpenAPI can't fully express a redirect/session-cookie exchange.)

## Architecture

**Dependency:** add `{:open_api_spex, "~> 3.x"}` to `mix.exs`.

**Spec module** `lib/perfect_paper_web/api/spec.ex` (`PerfectPaperWeb.Api.Spec`) — implements the `OpenApiSpex.OpenApi` behaviour:
- `info`: title "PerfectPaper API", version (from `mix.exs` `@version` or a constant), description (scholarly brand voice), contact/license = `TBD`/standard.
- `servers`: derived from endpoint config (e.g. `https://<host>/`).
- `paths`: `OpenApiSpex.Paths.from_router(PerfectPaperWeb.Router)` — collects the per-action `operation` annotations.
- `components.securitySchemes`: matches the two real auth surfaces (see `tokens.ex` + `plugs/ApiAuth`): **`bearerAuth`** (HTTP bearer — a session token) and **`apiKeyAuth`** (API key via `Authorization: Bearer <key>` resolved by `ApiKeys.verify/1`). Document the precedence (session token first, else API key).

**Controller annotations** (`OpenApiSpex.ControllerSpecs`): each action in `HistoryController`, `CreditController`, and the auth controllers gets an `operation :action, summary:, parameters:, request_body:, responses:` referencing schema modules. Tag by resource (`History`, `Credit`, `Auth`).

**Schema modules** `lib/perfect_paper_web/api/schemas.ex` (or a `api/schemas/` dir): `Session`, `Comment`, `CreditScore`, the **error envelope** (`%{detail: string | [%{loc, msg}]}` — must match `FallbackController`'s FastAPI-style envelope exactly), `LoginRequest`, etc. Each is an `OpenApiSpex.Schema` struct with field types/examples mirroring the real JSON views (`history_json.ex`, `credit_json.ex`).

**Serving:**
- `GET /api/openapi.json` → `OpenApiSpex.Plug.RenderSpec` (renders `Api.Spec`).
- `GET /api/docs` → a small controller/plug returning Redoc HTML that points at `/api/openapi.json`. Redoc loaded via a pinned CDN `<script>` (or vendored asset). Themed with the `paper` palette (Mulberry `#7a2e4e` primary, etc.) via Redoc theme options; `font-display`/`font-serif` where Redoc allows.
- Both routes are in a **public** pipeline (no auth plug), in the router.
- Wire `OpenApiSpex.Plug.PutApiSpec` into the `/api` pipeline so the spec is available (does NOT enable validation).

## Testing
- `GET /api/openapi.json` returns 200 + valid JSON; assert key paths present (e.g. `/api/history/{id}`, `/api/credit-score`).
- The spec is internally valid — use `OpenApiSpex` spec validation (e.g. `OpenApiSpex.OpenApi.to_map` + a schema-validity assertion, or `mix openapi.spec.json` round-trip) so a malformed annotation fails the build.
- `GET /api/docs` returns 200 HTML containing the Redoc mount + the `/api/openapi.json` URL.
- A test asserting every documented controller action has an `operation` (no silently-undocumented endpoint) — iterate the `/api` routes and check each has a spec entry.

## Out of scope (this pass)
- `CastAndValidate` request/response enforcement (behavior change) — future opt-in.
- SDK/client generation from the spec.
- Versioned API / multiple spec versions.
- GraphQL (still out of scope per CLAUDE.md).

## Definition of done
- `open_api_spex` added; `Api.Spec` + schema modules + controller annotations covering ALL `/api` endpoints.
- `/api/openapi.json` serves a valid OpenAPI 3.1 doc; `/api/docs` serves a brand-themed Redoc page; both public.
- Error responses documented with the real `{detail: ...}` envelope; the two security schemes documented.
- Tests green (spec served + valid, docs page served, every endpoint documented); `mix precommit` green.

## Open questions
1. **API version string** — use `mix.exs` `@version`, or a dedicated API version (e.g. "1.0")? Default: reuse `@version` unless told otherwise.
2. **Redoc delivery** — CDN `<script>` (simplest) vs vendoring the JS into `priv/static` (no external runtime dependency, better for air-gapped/enterprise). Default: CDN now, note vendoring as a hardening follow-up.
