# REST API Docs (OpenApiSpex + Redoc) — Implementation Plan (Spec 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Code-derived OpenAPI 3.1 spec (via `open_api_spex`) served at `/api/openapi.json`, plus a public, brand-themed Redoc reference at `/api/docs`, documenting all `/api` endpoints. No change to existing API behavior.

**Architecture:** `PerfectPaperWeb.Api.Spec` implements `OpenApiSpex.OpenApi`; controllers annotate actions via `OpenApiSpex.ControllerSpecs`; schema modules mirror the JSON views + the `FallbackController` error envelope; `PutApiSpec` is wired into the `/api` pipeline (NO request validation). Redoc is loaded from a pinned CDN and themed to the `paper` palette.

**Tech Stack:** Elixir/Phoenix 1.8, `open_api_spex ~> 3.x`. Spec: `docs/superpowers/specs/2026-06-02-rest-api-docs-design.md`.

---

## IMPORTANT for every task
`open_api_spex`'s exact module/macro API varies by version. The code blocks below are the canonical 3.x shape. **Before coding, consult the installed version's hexdocs (`mix hex.info open_api_spex`, and the `OpenApiSpex`, `OpenApiSpex.ControllerSpecs`, `OpenApiSpex.Plug.*`, `OpenApiSpex.Paths`, `OpenApiSpex.Schema` modules)** and adapt names/signatures to what's actually exported. **The acceptance gate is the task's test passing**, not byte-matching the snippet. If the real API differs, follow the real API and report the deviation.

## File structure
**Create:** `lib/perfect_paper_web/api/spec.ex`; `lib/perfect_paper_web/api/schemas.ex`; `lib/perfect_paper_web/controllers/api/docs_controller.ex` (Redoc page); `test/perfect_paper_web/api_docs_test.exs`.
**Modify:** `mix.exs` (dep); `lib/perfect_paper_web/router.ex` (pipeline + routes); `lib/perfect_paper_web/controllers/api/history_controller.ex`, `credit_controller.ex`, and the auth controllers (`user_session_controller.ex`, `o_auth_controller.ex` — confirm names) (annotations).

---

## Task 1: Dependency + spec skeleton + served `/api/openapi.json`

**Files:** `mix.exs`; `lib/perfect_paper_web/api/spec.ex`; `lib/perfect_paper_web/router.ex`; `test/perfect_paper_web/api_docs_test.exs`.

- [ ] **Step 1 — add dep.** In `mix.exs` deps: `{:open_api_spex, "~> 3.21"}` (or latest 3.x — check `mix hex.info open_api_spex`). Run `mix deps.get`.

- [ ] **Step 2 — failing test** `test/perfect_paper_web/api_docs_test.exs`:
```elixir
defmodule PerfectPaperWeb.ApiDocsTest do
  use PerfectPaperWeb.ConnCase, async: true

  test "GET /api/openapi.json serves a valid OpenAPI document", %{conn: conn} do
    conn = get(conn, "/api/openapi.json")
    assert %{"openapi" => version, "info" => info, "paths" => paths} = json_response(conn, 200)
    assert version =~ ~r/^3\./
    assert info["title"] == "PerfectPaper API"
    assert is_map(paths)
  end
end
```

- [ ] **Step 3 — run, expect FAIL** (route/spec missing): `mix test test/perfect_paper_web/api_docs_test.exs`

- [ ] **Step 4 — spec module** `lib/perfect_paper_web/api/spec.ex` (canonical shape — adapt to installed API):
```elixir
defmodule PerfectPaperWeb.Api.Spec do
  @moduledoc "The OpenAPI 3.1 specification for the PerfectPaper REST API (code-derived)."
  @behaviour OpenApiSpex.OpenApi
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PerfectPaperWeb.{Endpoint, Router}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PerfectPaper API",
        version: Application.spec(:perfect_paper, :vsn) |> to_string(),
        description: "REST API for PerfectPaper — upload manuscripts, retrieve referee-grade feedback, and act on it."
      },
      servers: [Server.from_endpoint(Endpoint)],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer",
            description: "A session token (Authorization: Bearer <token>). Takes precedence over an API key."},
          "apiKeyAuth" => %SecurityScheme{type: "http", scheme: "bearer",
            description: "An API key presented as Authorization: Bearer <key>, resolved by ApiKeys.verify/1."}
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
```

- [ ] **Step 5 — wire pipeline + routes** in `lib/perfect_paper_web/router.ex`:
  - Into the existing `/api` pipeline (the one feeding `PerfectPaperWeb.Api`), add `plug OpenApiSpex.Plug.PutApiSpec, module: PerfectPaperWeb.Api.Spec`. (This only attaches the spec; it does NOT validate requests.)
  - Add a PUBLIC route (no auth plug) `get "/api/openapi.json", OpenApiSpex.Plug.RenderSpec, []`. Ensure it's reachable without authentication (put it in a pipeline that doesn't require a user). If `PutApiSpec` must run before `RenderSpec`, ensure the route's pipeline includes it.

- [ ] **Step 6 — run, expect PASS.** `mix test test/perfect_paper_web/api_docs_test.exs`. If `Paths.from_router` returns empty paths (no annotations yet) and the test's `paths` assertion needs entries, it's fine for now (assert `is_map(paths)` only). `mix compile --warnings-as-errors` clean.

- [ ] **Step 7 — commit:**
```bash
git add mix.exs mix.lock lib/perfect_paper_web/api/spec.ex lib/perfect_paper_web/router.ex test/perfect_paper_web/api_docs_test.exs
git commit -m "feat(api-docs): add open_api_spex; serve /api/openapi.json (spec skeleton)"
```

---

## Task 2: Schema modules

**Files:** `lib/perfect_paper_web/api/schemas.ex`; test append.

- [ ] **Step 1 — read the JSON views** `lib/perfect_paper_web/controllers/api/history_json.ex` and `credit_json.ex` and the `FallbackController` to mirror the EXACT response shapes (field names, the `{detail: ...}` error envelope — `detail` is a string for plain errors and a list of `%{loc, msg}` for 422 changeset errors).

- [ ] **Step 2 — write schemas** `lib/perfect_paper_web/api/schemas.ex` — one `OpenApiSpex.Schema`-implementing module per type (canonical shape — adapt to installed API):
```elixir
defmodule PerfectPaperWeb.Api.Schemas do
  alias OpenApiSpex.Schema

  defmodule Comment do
    require OpenApiSpex
    OpenApiSpex.schema(%{
      title: "Comment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        original_text: %Schema{type: :string},
        suggestion: %Schema{type: :string},
        explanation: %Schema{type: :string},
        category: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["open", "dismissed", "addressed"]},
        position: %Schema{type: :integer}
      }
    })
  end

  defmodule Session do
    require OpenApiSpex
    OpenApiSpex.schema(%{
      title: "Session",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        processing_status: %Schema{type: :string},
        is_public: %Schema{type: :boolean},
        overall_feedback: %Schema{type: :string, nullable: true},
        comments: %Schema{type: :array, items: PerfectPaperWeb.Api.Schemas.Comment}
      }
    })
  end

  defmodule CreditScore do
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "CreditScore", type: :object, properties: %{ ... mirror credit_json ... }})
  end

  defmodule Error do
    require OpenApiSpex
    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      description: "FastAPI-style error envelope.",
      properties: %{detail: %Schema{oneOf: [%Schema{type: :string}, %Schema{type: :array, items: %Schema{type: :object}}]}}
    })
  end

  defmodule LoginRequest do
    require OpenApiSpex
    OpenApiSpex.schema(%{title: "LoginRequest", type: :object, properties: %{email: %Schema{type: :string}, password: %Schema{type: :string}}, required: [:email, :password]})
  end
end
```
Fill `CreditScore`/`Session`/`Comment` fields to EXACTLY match the JSON views. Add any other request/response schema the endpoints need.

- [ ] **Step 3 — quick test** asserting the schemas compile and resolve (e.g. `assert PerfectPaperWeb.Api.Schemas.Session.schema().title == "Session"`). Run, expect PASS after writing.

- [ ] **Step 4 — commit:** `git commit -m "feat(api-docs): OpenAPI schema modules mirroring JSON views + error envelope"`

---

## Task 3: Annotate History + Credit controllers

**Files:** modify `history_controller.ex`, `credit_controller.ex`; test append.

- [ ] **Step 1 — annotate** each action with `OpenApiSpex.ControllerSpecs` `operation/2` (canonical shape — adapt to installed API). Add `use OpenApiSpex.ControllerSpecs` (or `import`/`plug` per the version) to each controller, then per action e.g.:
```elixir
  operation :show,
    summary: "Fetch one proofreading session",
    parameters: [id: [in: :path, type: :string, description: "Session id", required: true]],
    responses: [
      ok: {"Session", "application/json", PerfectPaperWeb.Api.Schemas.Session},
      not_found: {"Not found", "application/json", PerfectPaperWeb.Api.Schemas.Error}
    ]
```
Cover ALL History actions (index, show, delete, mark_viewed, set_visibility, dismiss, address) — with the 404/403/422 responses referencing `Error` where they apply (delete→204 no_content; dismiss/address→200 Comment or 403/404). Tag `"History"`. Annotate `CreditController.show` (tag `"Credit"`). Add a `security:` entry (bearerAuth/apiKeyAuth) on the operations that require auth.

- [ ] **Step 2 — test** that the served spec now includes these paths:
```elixir
  test "documents the history + credit endpoints", %{conn: conn} do
    paths = get(conn, "/api/openapi.json") |> json_response(200) |> Map.fetch!("paths")
    assert Map.has_key?(paths, "/api/history")
    assert Map.has_key?(paths, "/api/history/{id}")
    assert Map.has_key?(paths, "/api/credit-score")
  end
```
(Confirm the path-templating style OpenApiSpex emits — `{id}` vs `:id` — and match the assertion to reality.)

- [ ] **Step 3 — run PASS; `mix compile --warnings-as-errors` clean; commit:** `git commit -m "feat(api-docs): annotate History + Credit controllers with OpenAPI operations"`

---

## Task 4: Annotate auth controllers

**Files:** modify the auth controllers (`grep -rln "def create\|def callback\|update_password" lib/perfect_paper_web/controllers` to locate; likely `user_session_controller.ex` + `o_auth_controller.ex`); test append.

- [ ] **Step 1 — annotate** `POST /api/users/log-in`, `DELETE /api/users/log-out`, `POST /api/users/update-password`, `GET /api/auth/:provider`, `GET /api/auth/:provider/callback`. Tag `"Auth"`. Use `LoginRequest` for the login body. For cookie/redirect flows that OpenAPI can't fully express, document the response as a 302/redirect or session-cookie set, with a `description` noting the browser/session semantics. Do NOT change controller logic — annotations only.

- [ ] **Step 2 — test** that `/api/users/log-in` (and the auth paths) appear in the served spec. Run PASS.

- [ ] **Step 3 — commit:** `git commit -m "feat(api-docs): annotate auth endpoints (login/logout/password/oauth)"`

---

## Task 5: Redoc docs page at `/api/docs` (public, brand-themed)

**Files:** `lib/perfect_paper_web/controllers/api/docs_controller.ex`; `router.ex`; test append.

- [ ] **Step 1 — failing test:**
```elixir
  test "GET /api/docs serves a Redoc page referencing the spec", %{conn: conn} do
    html = get(conn, "/api/docs") |> html_response(200)
    assert html =~ "redoc"
    assert html =~ "/api/openapi.json"
  end
```

- [ ] **Step 2 — docs controller** `lib/perfect_paper_web/controllers/api/docs_controller.ex` — returns an HTML page that mounts Redoc against `/api/openapi.json`. Use a pinned Redoc CDN script (e.g. `https://cdn.redoc.ly/redoc/v2.x.x/bundles/redoc.standalone.js` — pin an exact version). Theme via the Redoc `<redoc>` `theme`/options or an `options-json` to the `paper` palette: primary Mulberry `#7a2e4e`, text Ink `#211c18`, background cream `#fbf8f2`; headings in a serif/display face where Redoc allows. Send as `:html` (`put_resp_content_type("text/html") |> send_resp(200, html)` or a HEEx/`~H` rendered string). No external data beyond the Redoc CDN script + the local spec URL.

- [ ] **Step 3 — route** (PUBLIC, no auth): `get "/api/docs", PerfectPaperWeb.Api.DocsController, :index`. Place in a pipeline without auth requirements.

- [ ] **Step 4 — run PASS; commit:** `git commit -m "feat(api-docs): public brand-themed Redoc reference at /api/docs"`

---

## Task 6: Coverage test + spec validity + precommit

**Files:** test append; verification.

- [ ] **Step 1 — every-endpoint-documented test.** Add a test that iterates the `/api`-scoped routes from `PerfectPaperWeb.Router.routes/0` (filter to the `Api` controllers + the auth API routes) and asserts each has a corresponding entry in the served spec's `paths` (so no endpoint is silently undocumented). If some auth routes are intentionally only partially modeled, assert at least their path is present.

- [ ] **Step 2 — spec-validity assertion.** Add a test that the spec is structurally valid — e.g. `PerfectPaperWeb.Api.Spec.spec()` builds without raising and `OpenApiSpex.OpenApi.to_map/1` succeeds; if the installed version exposes a spec validator, use it. (Goal: a malformed annotation fails the suite.)

- [ ] **Step 3 — run all api docs tests PASS.**

- [ ] **Step 4 — `mix format` + `mix precommit`** — fully green. Fix any caller/format issue (do NOT disable validation or change API behavior). If precommit's `mix format` reformats files, `git add -A` them into the final commit so the tree is format-clean.

- [ ] **Step 5 — commit:**
```bash
git add -A
git commit -m "test(api-docs): endpoint-coverage + spec-validity; precommit green"
```

---

## Self-review (authoring)
- **Spec coverage:** dep + spec served (T1) ✓; schemas mirroring views + error envelope (T2) ✓; History+Credit annotations (T3) ✓; auth annotations (T4) ✓; public brand-themed Redoc (T5) ✓; coverage + validity + precommit (T6) ✓; two security schemes documented (T1/T3) ✓; NO request-validation enforcement (PutApiSpec only) ✓; public access ✓.
- **No behavior change:** annotations + PutApiSpec are inert w.r.t. request handling; existing API tests must stay green (T6 precommit).
- **Library-version risk:** every task says verify the installed open_api_spex API and treats the test as the gate.
- **Placeholders:** schema field lists in T2 marked to mirror the real JSON views (implementer fills from the actual views) — not a TODO, an instruction to read source of truth.
