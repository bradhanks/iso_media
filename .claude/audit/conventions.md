# Shared Audit Conventions — read this file first, every run

Every audit subagent reads this, then applies the ASVS 5.0 chapter(s) it owns. Stack:
**PerfectPaper** — Elixir, Phoenix LiveView on Bandit, Absinthe GraphQL + REST, Ecto/Postgres.
Confirm the real module/dir names from `mix.exs` and `lib/` before auditing; this doc assumes
`PerfectPaper` (`lib/perfect_paper`) and `PerfectPaperWeb` (`lib/perfect_paper_web`).

## Standard

Findings are scored against **OWASP ASVS 5.0.0** (May 2025, 17 chapters). **Cite every finding**
with its requirement id as `v5.0.0-<chapter>.<section>.<requirement>` (e.g. `v5.0.0-8.1.1`).
Target bar: **ASVS Level 2** for anything handling real user data; **Level 3** for high-assurance
paths (EngineeringID signing/sealing). Each ASVS chapter opens with *Documented Security
Decisions* requirements — if a control's choice isn't written down where ASVS expects, that's a
finding too.

## Request lifecycle (where to look)

Two paths. **Path A (HTTP dead render):** Bandit → Endpoint plugs → Router pipeline →
`LiveView.Plug`/controller → `on_mount` → `mount/3` (disconnected) → `handle_params` → `render`.
**Path B (WebSocket):** Bandit upgrade (signed session + CSRF token) → process spawn → `on_mount`
→ `mount/3` (connected) → `handle_params` → `handle_event`/`handle_info`/`handle_async` → context
→ changeset → `Repo` → Postgres. Coarse gates (endpoint/router/on_mount) authorize *reaching* a
view; real enforcement lives at the *operation* (context function / event handler / query).

## File scope map

| Node | Files |
|---|---|
| Endpoint | `lib/perfect_paper_web/endpoint.ex` |
| Router + `live_session` | `lib/perfect_paper_web/router.ex` |
| Plugs / auth | `lib/perfect_paper_web/user_auth.ex`, `lib/perfect_paper_web/plugs/**/*.ex` |
| LiveViews | `lib/perfect_paper_web/live/**/*.ex` |
| Controllers | `lib/perfect_paper_web/controllers/**/*.ex` |
| GraphQL | `lib/perfect_paper_web/schema*.ex`, `schema/**`, `resolvers/**`, dataloader sources |
| Contexts | `lib/perfect_paper/*.ex` |
| Schemas / changesets | `lib/perfect_paper/<context>/*.ex` |
| Migrations | `priv/repo/migrations/*.exs` |
| Config | `config/*.exs`, `config/runtime.exs` |

Stay within this map. Out-of-scope changes (assets, deps, JS) are flagged, not made.

## Load-bearing rules (cross-cutting)

1. Ownership goes in the `WHERE` clause, never an `if` after the fetch.
2. The scope is the first argument of every context function.
3. A non-owned resource returns 404 (`Ecto.NoResultsError`), never 403.
4. Never `cast` owner/tenant FKs (`user_id`, `org_id`) from params — set them from the scope.
5. The web layer calls contexts, never `Repo` directly.
6. Nested resources resolve through their parent's scope.
7. UUIDs/opaque ids reduce blast radius; they are not authorization.

## Operating mode

- **READ-ONLY.** Audit and report; do not edit files. (A fix pass is a separate, explicitly
  fix-enabled invocation.)
- Run all commands from the repo root; `cd` does not persist between Bash calls.
- Bash is allowlist-restricted to `mix format|credo|compile|test`, `rg`/`grep`, and read-only
  file/git inspection. Other shell commands are blocked — if a step needs one, log it as a
  finding rather than retrying.
- Scope each run to one context/slice unless told otherwise.

## Report schema (emit exactly this so findings merge across agents)

One line per finding:

```
path:line · v5.0.0-X.Y.Z · HIGH | MED | LOW · <chapter> · <issue> · <recommended fix>
```

End with: a count by severity, and any ASVS sections you judged **Not Applicable** (one line of
why each). Recommended fixes are *described*, not applied.
