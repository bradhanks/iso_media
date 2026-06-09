# SOC 2 Readiness — Evidence Register

**Artifact type:** Type II readiness (not an audit report)
**Audit period:** TBD
**Last updated:** 2026-06-02

This register lists the concrete artifacts that demonstrate the effectiveness of each
Implemented or Partial control. For Implemented controls, the artifacts are available
today and constitute genuine audit evidence. For Partial controls, the artifacts
demonstrate what is in place and make the gap explicit; the gap entry in `gaps.md`
records what is missing.

---

## CC6.1 — Logical access: authorization (Implemented)

### Artifact 1 — `PerfectPaper.Authz.permit?/4` choke point

**File:** `lib/perfect_paper/authz.ex`

`permit?/4` is the single function that answers "may this subject perform this action
on this resource?" Every controller, context function, and LiveView that mediates access
to a session must call it; the codebase contains no bypassed code path. The function
evaluates ownership (direct user ownership), group membership via PostgreSQL ltree
path comparison, and explicit resource grants, then returns `:ok` or an error tuple.

**What the auditor sees:** A grep of the codebase for any `Repo.get` or list query
against `History.Session` routes through `scope_query/3` (for reads) or `permit?/4`
(for mutations). There is no unmediated path.

### Artifact 2 — `PerfectPaper.Authz.Role` role ladder

**File:** `lib/perfect_paper/authz/role.ex`

Defines the fixed, totally-ordered role ladder (`:viewer < :commenter < :editor < :admin < :owner`) and the minimum role required for each action. The mapping is code — not configuration or database data — and therefore subject to version control and test coverage.

### Artifact 3 — `PerfectPaper.Authz.ResourceGrant` grant table

**File:** `lib/perfect_paper/authz/resource_grant.ex`
**Migration:** `priv/repo/migrations/20260602100300_create_resource_grants.exs`

The `resource_grants` table records every explicit sharing grant: resource type,
resource id, subject type, subject id, role assigned, and the `granted_by` user id.
A unique constraint (resource_type, resource_id, subject_type, subject_id) prevents
duplicate grants. The table is auditable row-by-row.

### Artifact 4 — `PerfectPaper.Authz.scope_query/3`

**File:** `lib/perfect_paper/authz.ex` (`scope_query/3` function)

The list-query scoping function narrows any `Session` query to rows the subject may
read: owned directly, owned by a group whose ltree path the subject's membership
covers, or covered by an explicit resource grant. No unscoped list query may return
sessions the subject has no right to see.

### Artifact 5 — Authz ExUnit tests

**File:** `test/perfect_paper/authz_test.exs`
**Supporting fixtures:** `test/support/fixtures/authz_fixtures.ex`

Tests cover permit? outcomes for each role tier, the deny path for insufficient role,
the not-found path for no line of sight, group-inheritance via ltree, and grant-based
access. These tests prove the policy engine behaves as documented and run on every CI
pass.

---

## CC6.1 — Logical access: authentication (Partial)

### Artifact 1 — `PerfectPaperWeb.UserAuth` session management

**File:** `lib/perfect_paper_web/user_auth.ex`

`fetch_current_scope_for_user/2` resolves the current scope from the session token or
signed remember-me cookie. `require_authenticated_user/2` (Plug) and the
`on_mount :require_authenticated` LiveView hook halt unauthenticated requests.
Session tokens are reissued every 7 days for active users; cookie max-age is 14 days.
`renew_session/2` calls `configure_session(renew: true)` and `clear_session/0` on
login to prevent session-fixation attacks.

### Artifact 2 — `phx.gen.auth` password authentication

`PerfectPaper.Accounts.generate_user_session_token/1` and
`PerfectPaper.Accounts.get_user_by_session_token/1` handle token creation and
resolution. Password hashing follows the `phx.gen.auth` defaults (Bcrypt via
`Pbkdf2` or equivalent, configurable). Session tokens stored as `user_tokens` with
`context: "session"`.

### Artifact 3 — MFA scaffold (Partial — scaffold only)

**Files:**
- `lib/perfect_paper/accounts/mfa.ex` — `Accounts.MFA` behaviour with `@callback` typespecs for `begin_enrollment/2`, `confirm_enrollment/2`, `begin_verification/1`, `verify/2`
- `lib/perfect_paper/accounts/mfa/totp.ex` — `Accounts.MFA.TOTP` stub adapter (returns `{:error, :not_implemented}` with `TODO(mfa)` notes)
- `lib/perfect_paper/accounts/mfa/web_authn.ex` — `Accounts.MFA.WebAuthn` stub adapter (same pattern)
- `lib/perfect_paper/accounts/mfa/factor.ex` — `Accounts.MFA.Factor` schema for `user_mfa_factors` table
- `lib/perfect_paper/accounts/mfa/recovery_code.ex` — `Accounts.MFA.RecoveryCode` schema for `mfa_recovery_codes` table
- Migration: `priv/repo/migrations/20260602110000_create_mfa.exs`

The seam is in place: the behaviour, the adapter pattern, the data model. What is not
yet implemented is the enrollment/verification flow and the MFA gate at login. See
`gaps.md` for the open items.

---

## CC6.1 — Recovery codes: hash-only storage (Partial)

**File:** `lib/perfect_paper/accounts/mfa/recovery_code.ex`

The `mfa_recovery_codes` schema stores a `code_hash` field (string) rather than the
plaintext recovery code. The changeset requires `code_hash` to be present. What is
missing is the hash function applied at write time — the column is correct, the write
path is not yet implemented. Noted as `TODO(mfa)` in the module doc.

---

## CC6.2 — Registration and deprovisioning (Partial)

### Artifact — `PerfectPaper.Accounts` registration

`Accounts.register_user/1` and the associated changeset in `lib/perfect_paper/accounts/user.ex` validate and persist new user records. Session token deletion on logout
(`Accounts.delete_user_session_token/1`) and on account deletion handle the
deprovisioning path. Foreign key constraints in the schema cascade or nullify
dependent records.

**What is absent:** No automated SCIM-based deprovisioning. No org-enforced offboarding
workflow. These are tracked as future Spec 3 work.

---

## CC6.3 — Least privilege and role assignment (Partial)

### Artifact — `resource_grants.granted_by`

The `resource_grants` table records the `granted_by` user id for every grant. This
provides an audit trail of who assigned access to whom. The `Authz.Role` module
enforces that `:admin` role is the minimum required to grant access (`share` and
`manage_members` actions require `:admin`).

**What is absent:** No periodic access review process. No UI for listing and revoking
outstanding grants. These are process gaps.

---

## CC5.2 — Session fixation and general technology controls (Partial)

### Artifact — `PerfectPaperWeb.UserAuth.create_or_extend_session/3` → `renew_session/2`

**File:** `lib/perfect_paper_web/user_auth.ex` (lines 146–152)

On login, the public entry point `create_or_extend_session/3` generates a session token and then calls the private helper `renew_session/2`. `renew_session/2` contains a no-op guard clause that short-circuits when the user is already authenticated (matching `current_scope.user.id`); for a new login it calls `delete_csrf_token/0`, `configure_session(renew: true)`, and `clear_session/0` before the token is stored. This is the standard Phoenix session-fixation mitigation.

### Artifact — `PerfectPaperWeb.Plugs.UnicodeSanitizer` (request boundary)

Applied at the request boundary via a Plug; strips invisible Unicode injection payloads before any controller or LiveView processes the params. Backed by `PerfectPaper.Security.UnicodeSanitizer`.

---

## CC6.8 — Input integrity: prompt-injection defense (Implemented)

### Artifact 1 — `PerfectPaper.Security.UnicodeSanitizer`

**File:** `lib/perfect_paper/security/unicode_sanitizer.ex`

Pure-functional module. Detects and strips two attack categories:
- Zero-width binary encoding (U+200B / U+200C used as bit-pairs to encode hidden ASCII)
- Unicode Tags block (U+E0000–U+E007F, deprecated language tags still decoded by LLM tokenizers)

Exposes `scan/1`, `sanitize/1`, `sanitize_params/1`, `scan_params/2`, and the Ecto changeset validator `validate_no_hidden_unicode/2`. No IO; fully testable in isolation.

### Artifact 2 — Request-level Plug

The `PerfectPaperWeb.Plugs.UnicodeSanitizer` plug applies `UnicodeSanitizer.sanitize_params/1` to all incoming request parameters, before they reach any controller action or LiveView event handler.

### Artifact 3 — Changeset-level validator

`validate_no_hidden_unicode/2` is available as a defense-in-depth validator for
high-value text fields (document titles, content, chat messages). Applied in
changesets that accept user-supplied manuscript content.

### Artifact 4 — Test coverage

Tests for `UnicodeSanitizer` cover the zero-width encoding detection path, the
Unicode Tags detection path, the sanitize round-trip, the params-map recursion, and
the changeset validator. These tests run on every CI pass.

---

## CC7.2 — Audit logging of mutating authorization decisions (Implemented)

### Artifact 1 — `PerfectPaper.Authz.Decision` schema

**File:** `lib/perfect_paper/authz/decision.ex`

Append-only schema (`updated_at: false`). Fields: `subject_id`, `action`,
`resource_type`, `resource_id`, `decision` (string: "ok", "unauthorized",
"not_found"), `reason` (string: "owner", "group_inheritance", "grant"), `inserted_at`.

### Artifact 2 — `authz_decisions` migration

**File:** `priv/repo/migrations/20260602100400_create_authz_decisions.exs`

Creates the `authz_decisions` table with `NOT NULL` constraints on `action`,
`resource_type`, and `decision`. Indexes on `subject_id` and `(resource_type, resource_id)` support efficient queries. The migration uses `timestamps(updated_at: false)` —
the table is structurally append-only.

### Artifact 3 — `PerfectPaper.Authz.maybe_log/5`

**File:** `lib/perfect_paper/authz.ex` (private function, lines 135–150)

Called unconditionally at the end of `permit?/4`. Writes a decision row for every
mutating action (`:edit`, `:delete`, `:share`, `:manage_members`) determined by
`Role.mutating?/1`. Read actions (`:read`, `:comment`) are not logged in Spec 1 —
this is a documented gap.

### Artifact 4 — `webhook_deliveries` outbound delivery log

**Files:** `lib/perfect_paper/webhooks/delivery.ex` (schema), called via `PerfectPaper.Webhooks.Delivery.Worker` (Oban job)
**Migration:** `priv/repo/migrations/20260602120100_create_webhooks.exs` (creates both `webhook_endpoints` and `webhook_deliveries`)

The `webhook_deliveries` table is an audit record of every outbound webhook dispatch.
One row is created per (endpoint, event) pair and updated in place across retry
attempts: `endpoint_id`, `event_type`, `event_id`, `payload`, `status`
(pending / delivered / failed), `attempts` (integer — incremented on each dispatch
attempt by the Oban worker), `response_status` (HTTP status from the receiving server),
`last_error` (string — transport error or non-2xx description, null on success), and
`inserted_at` / `updated_at` timestamps. `delivered_at` is set when the first 2xx
response is received. This log provides evidence that outbound system-activity
notifications were attempted and whether they succeeded, directly supporting monitoring
and operational audit of the webhook delivery pipeline.

**What this is not:** anomaly detection or real-time alerting. The log is queryable
evidence of delivery activity; no automated alerting or SIEM integration is currently
wired (see CC7.3 gap).

### Artifact 5 — Sample row shape

A representative `authz_decisions` row contains:

| Field | Example value |
|---|---|
| id | UUID |
| subject_id | UUID of the acting user |
| action | "delete" |
| resource_type | "session" |
| resource_id | UUID of the session |
| decision | "ok" or "unauthorized" |
| reason | "owner", "group_inheritance", or "grant" |
| inserted_at | 2026-06-02T14:23:01Z |

This is queryable evidence of every mutating access attempt, including denied
attempts.

---

## CC8.1 — Change management (Process)

### Artifact 1 — `CLAUDE.md` Git and TDD workflow

**File:** `CLAUDE.md` (section "Git & TDD workflow")

Documents the mandatory practice: every code change ships on a uniquely named feature
branch cut from `main`; tests are written before implementation (red-green-refactor);
`mix precommit` (compile --warnings-as-errors, deps.unlock --unused, format, full
test suite) must pass; the branch is merged back to `main` only after the gate clears.

### Artifact 2 — Reversible Ecto migrations

**Directory:** `priv/repo/migrations/`

All schema changes are Ecto migrations with timestamps in the filename. Migrations
use `change/0` (or explicit `up/down`) to support rollback. The migration history is
append-only in version control and constitutes a full schema-change audit trail.

### Artifact 3 — Commit and branch history

The Git log for this repository is the authoritative record of what changed, when,
and (via commit message) why. The naming convention for specification-driven work
(e.g., `feat/authz-spec1`, `feat/mfa-soc2-scaffold`) makes audit trails legible.

---

## CC9.2 — Vendor isolation (Partial)

### Artifact — Adapter behaviour modules

| Vendor concern | Behaviour file |
|---|---|
| Language model | `lib/perfect_paper/chatbot/llm.ex` (`PerfectPaper.Chatbot.LLM`) |
| Blob storage | `lib/perfect_paper/documents/storage.ex` (`PerfectPaper.Documents.Storage`) |
| Payments | `lib/perfect_paper/billing/provider.ex` (`PerfectPaper.Billing.Provider`) |

Each behaviour defines `@callback`s with full typespecs; adapters return atom-keyed
maps matching Ecto schema fields. The config key (`:llm_provider`, `:storage_provider`,
`:billing_provider`) selects the active adapter. No vendor-specific SDK, credential
format, or error shape crosses the behaviour boundary into application code.

Formal vendor risk assessments, data processing agreements, and a published
sub-processor list are not yet documented — these are organizational gaps.
