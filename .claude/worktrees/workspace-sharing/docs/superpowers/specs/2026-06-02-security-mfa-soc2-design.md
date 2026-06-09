# Security & Compliance — MFA + SOC 2 Readiness (Spec 6) — Design

**Date:** 2026-06-02
**Status:** Draft — pending user review
**Nature of this pass:** **Scaffold + documentation.** Stub the requirements and place TODOs where the code goes; write the SOC 2 readiness documentation. This pass does **not** ship a working MFA enrollment/verification flow — it lays the seams, tables, enforcement points, and the auditor-facing docs so the actual build (and the audit) can proceed without rework.

## Why this exists

Enterprise procurement and security reviews gate on two things this product doesn't yet have: **MFA** and a **SOC 2** story. Both are identity/compliance concerns that sit on top of the Spec 1 authorization foundation (the `Authz` choke point and the `authz_decisions` audit log are already SOC 2 evidence). This spec scaffolds MFA and maps SOC 2 controls to code so the gaps are explicit and tracked.

## Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| MFA methods | **TOTP authenticator app** + **WebAuthn / passkeys**, both behind one `Accounts.MFA` behaviour + config-selected adapters (the repo's anti-corruption-layer pattern). SMS/email OTP intentionally excluded (weak factor; SOC 2 reviewers note it). |
| MFA enforcement | **Both** per-user opt-in (`users.mfa_enabled` + enrolled factors) **and** org-enforced (`organizations.mfa_required`). Enforced at three choke points: login (`user_auth.ex`), API token issuance (`tokens.ex` / `plugs/ApiAuth`), and LiveView `on_mount`. |
| SOC 2 depth | **Type II readiness + control→code map.** Trust Services Criteria: Security/Common Criteria (CC1–CC9, required) + Availability + Confidentiality. Each control mapped to a code location, status, and gap, with TODOs in code. |
| Build scope | **Scaffold only this pass.** Behaviour boundaries, table stub migrations, enforcement-point TODOs, and the SOC 2 docs. No working enrollment/verification UI or ceremonies yet. |

## Where this sits in the roadmap

Spec 6 of the enterprise decomposition (after Specs 1–5). Queue order set by the user: **6 (this) → 7 (REST docs) → 8 (webhooks/Oban)**. MFA is identity-adjacent to **Spec 3 (Entra SSO/SCIM)** — when SSO lands, MFA enforcement defers to the IdP for SSO users (a documented TODO here).

## Architecture — MFA (anti-corruption-layer pattern)

Follows CLAUDE.md law 7: side-effects behind a behaviour + config-selected adapter; adapters return atom-keyed maps matching schema fields.

```
lib/perfect_paper/accounts/mfa.ex            # behaviour (@callbacks) + the MFA seam doc
lib/perfect_paper/accounts/mfa/totp.ex       # TOTP adapter (STUB — @callbacks return :not_implemented / TODO)
lib/perfect_paper/accounts/mfa/web_authn.ex  # WebAuthn adapter (STUB — TODO)
lib/perfect_paper/accounts/mfa/factor.ex     # Ecto schema for an enrolled factor (real, minimal) + changeset
lib/perfect_paper/accounts/mfa/recovery_code.ex  # Ecto schema for recovery codes (real, minimal) + changeset
```

**Behaviour `Accounts.MFA` (the seam).** `@callback`s with full typespecs, e.g.:
- `begin_enrollment(user, type) :: {:ok, enrollment_challenge} | {:error, term}` — TOTP: secret + otpauth URI for QR; WebAuthn: registration challenge/options.
- `confirm_enrollment(user, type, attestation) :: {:ok, factor_attrs} | {:error, term}` — verifies the first proof; returns atom-keyed factor attrs for the changeset.
- `begin_verification(user) :: {:ok, challenge} | {:error, term}` — at login: TOTP no-op; WebAuthn assertion challenge.
- `verify(user, type, proof) :: :ok | {:error, :invalid}` — checks a code/assertion.

Config key (new): `config :perfect_paper, :mfa_provider, ...` selecting a dispatcher that routes by factor `type` to the TOTP/WebAuthn adapter. Both adapters are **stubs** this pass: each `@callback` body is a `# TODO(mfa): ...` returning `{:error, :not_implemented}` with a precise note of the library/ceremony needed (e.g. `:pot`/`nimble_totp` for TOTP; a WebAuthn lib + challenge/attestation storage for passkeys).

**Schemas (real, minimal — so the data model isn't a retrofit later):**

```
user_mfa_factors
  id          binary_id pk
  user_id     binary_id -> users
  type        enum [:totp, :webauthn]
  # opaque, adapter-owned material (TOTP secret / WebAuthn credential id + public key)
  secret      :binary        (encrypted at rest — TODO: app-level encryption, see SOC 2 CC6.7)
  label       :string        (e.g. device name)
  confirmed_at :utc_datetime  (nil until first successful proof)
  last_used_at :utc_datetime
  timestamps
  unique (user_id, type, label)

mfa_recovery_codes
  id        binary_id pk
  user_id   binary_id -> users
  code_hash :string         (hashed, never plaintext — TODO: hashing, CC6.1)
  used_at   :utc_datetime
  timestamps
```

Plus stub flags (real columns, scaffolded):
- `users.mfa_enabled :boolean default false` (and derived "has a confirmed factor").
- `organizations.mfa_required :boolean default false`.

**Context API (stubs in `Accounts`, the boundary).** `Accounts.mfa_required_for?(user)` (true if user opted in OR any of the user's orgs requires it), `Accounts.enroll_factor/…`, `Accounts.confirm_factor/…`, `Accounts.verify_mfa/…`, `Accounts.regenerate_recovery_codes/…` — each a stub with a `# TODO(mfa)` body and a changeset-validated signature, so the public API reads correctly even before the adapters work.

### Enforcement points (TODOs placed at the real call sites)

| Choke point | File | TODO |
|---|---|---|
| Browser login | `lib/perfect_paper_web/user_auth.ex` | After password auth, if `Accounts.mfa_required_for?(user)` and the session isn't MFA-verified → redirect to an MFA challenge step before establishing the full session. `# TODO(mfa): gate session establishment.` |
| API token issuance | `lib/perfect_paper_web/.../tokens.ex` + `plugs/ApiAuth` | Don't mint/accept a session bearer token for an MFA-required user without a verified factor. `# TODO(mfa): require verified factor before token issue.` |
| LiveView mount | `user_auth.ex` `on_mount` | A new `on_mount` hook `:require_mfa` that halts/redirects an authenticated-but-not-MFA-verified session when required. `# TODO(mfa): on_mount :require_mfa.` |
| Org policy | `Organizations` | `set_mfa_required(org, bool)` (admin action, gated by `Authz.permit?(scope, :manage_members, …)`). `# TODO(mfa): org enforcement toggle.` |

Each TODO is tagged `TODO(mfa):` so they're greppable, and cross-referenced from the SOC 2 control map.

## Architecture — SOC 2 documentation

```
docs/compliance/soc2/
  README.md       # what SOC 2 is for this product, Type II vs Type I, audit-period note
  readiness.md    # system description + scope + selected Trust Services Criteria + overall posture
  controls.md     # CC1–CC9 (+ Availability, Confidentiality) → code location / status / gap / owner
  evidence.md     # for each control: what artifact proves it (logs, configs, tests, policies)
  gaps.md         # consolidated open gaps, each linking to a TODO() tag in code
```

**Control→code mapping highlights (illustrative — full matrix in `controls.md`):**

| Criterion | Control (abridged) | Code location / evidence | Status |
|---|---|---|---|
| CC6.1 | Logical access — authorization | `PerfectPaper.Authz.permit?/4` choke point; `resource_grants`; role ladder | **Implemented** (Spec 1) |
| CC6.1 | Logical access — authentication | `user_auth.ex`; **MFA** scaffolding | **Partial** (MFA TODO) |
| CC6.2 | Registration/deprovisioning | `Accounts` + SCIM (Spec 3) | Gap → Spec 3 TODO |
| CC6.7 | Data at rest / in transit | TLS (endpoint); `user_mfa_factors.secret` encryption | **Partial** (encryption TODO) |
| CC7.2 | Audit logging / monitoring | `authz_decisions` audit log | **Implemented** (Spec 1, mutating actions) |
| CC7.x | Anomaly detection / alerting | (none yet) | Gap → future TODO |
| CC8.1 | Change management | Git + TDD workflow (CLAUDE.md); migrations | **Process documented** |
| A1.x | Availability / backups | hosting/Neon backups | Doc-only gap |
| C1.x | Confidentiality handling | data classification of manuscripts | Doc-only gap |

The doc explicitly **leverages Spec 1**: the `Authz` choke point and `authz_decisions` log are real, demonstrable CC6/CC7 evidence today — so the readiness story isn't starting from zero.

## What this pass delivers (Definition of done)

1. `Accounts.MFA` behaviour with fully-specced `@callback`s; `TOTP`/`WebAuthn` **stub adapters** (return `{:error, :not_implemented}` with precise `TODO(mfa):` notes).
2. **Real minimal schemas + migrations** for `user_mfa_factors`, `mfa_recovery_codes`, and the `users.mfa_enabled` / `organizations.mfa_required` columns — so the data model is not a future retrofit.
3. `Accounts` context **stub functions** (changeset-validated signatures, `TODO(mfa)` bodies) for enroll/confirm/verify/recovery + `mfa_required_for?/1`.
4. `TODO(mfa):` markers at the three enforcement choke points (`user_auth.ex` login + `on_mount`, API token path) and the org policy toggle — each greppable and referenced from the SOC 2 control map.
5. `docs/compliance/soc2/` — README, readiness, controls (full CC1–CC9 + A + C matrix), evidence, gaps — with every code-backed control linking to its module and every gap linking to a `TODO()` tag.
6. Tests for the **real** parts only (schemas/changesets, `mfa_required_for?/1` logic, the new columns); stub adapters are asserted to return `:not_implemented` so the seam is verified without faking a ceremony.

## Explicitly NOT in this pass (tracked as TODOs)

- Working TOTP secret generation / QR / code verification (needs a TOTP lib).
- WebAuthn registration/assertion ceremonies (needs a WebAuthn lib + browser JS).
- Secret-at-rest encryption + recovery-code hashing implementations (columns + TODO now).
- The MFA challenge UI/LiveViews and the actual login-flow redirect wiring.
- SSO-user MFA delegation to Entra (Spec 3 interaction).
- Anomaly detection/alerting (CC7) and formal availability/confidentiality controls.

## Open questions for review

1. **Schemas real vs fully stubbed?** This design makes the *tables* real (minimal) but the *adapters/flows* stubbed — rationale: data-model retrofits are the expensive kind, exactly what we avoided in Spec 1. If you'd rather defer even the tables to TODO comments, say so.
2. **TOTP/WebAuthn libraries** — I'll name candidates in the TODOs (e.g. `nimble_totp` for TOTP) but not add deps this pass. OK?
3. **SOC 2 audit firm / period** — `readiness.md` will leave the auditor and audit window as `TBD` placeholders for you to fill, unless you have them now.
