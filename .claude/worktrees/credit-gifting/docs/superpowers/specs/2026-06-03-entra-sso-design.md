# Enterprise SSO — Entra ID (OIDC + SAML), per-org (Spec 3a) — Design

**Date:** 2026-06-03
**Status:** Approved — SAML is fully real this pass (via `esaml`), no scaffold fallback (user decision). Adds a SAML dependency; handles per-org IdP credentials + domain-verification security.
**Nature:** Real build. Per-org enterprise SSO against Microsoft Entra ID via **OIDC (reusing the Assent seam) and SAML 2.0** (selectable per org), with email-domain routing and JIT provisioning into the org. SCIM provisioning/group-sync is the **separate following spec (3b)**.

## Why

Enterprise deals require "log in with your work account." Each customer org configures their own Entra tenant; their users authenticate there and are provisioned into the org just-in-time. The OAuth/Assent seam, `user_identities`, and a security-aware JIT flow (`resolve_identity`) already exist — this generalizes them to **per-org, multi-protocol** SSO.

## Locked decisions (brainstorming)

| Decision | Choice |
|---|---|
| Sequencing | **Spec 3a = SSO now; Spec 3b = SCIM next** (independent). |
| Protocol | **Both OIDC + SAML, both fully real**, selectable per org. OIDC reuses the Assent seam. **SAML is real via `esaml`** — per-org dynamic IdP config + full XML signature/assertion validation (no scaffold). |
| Tenancy/routing | **Per-org config + email-domain routing.** `org_sso_configs` (org, protocol, creds/metadata, verified email_domain, enabled). Login: email → domain → org's IdP → JIT into that org. |

## Architecture

### Generalize the SSO seam (per-org, multi-protocol)
Today `Accounts.OAuth` is a behaviour with ONE global Assent adapter selected by config, per *provider* (google/github). SSO here is per-**org** and per-**protocol**, so we introduce a higher-level seam:

`Accounts.SSO.Provider` behaviour (anti-corruption layer), returning the SAME normalized `identity` map the OAuth seam already uses (`provider, uid, email, email_verified, name`):
- `@callback authorize_url(config :: SsoConfig.t(), session_params) :: {:ok, %{url, session_params}} | {:error, term}`
- `@callback callback(config :: SsoConfig.t(), params, session_params) :: {:ok, identity} | {:error, term}`

Two adapters, dispatched by `config.protocol`:
- **`SSO.OIDC`** — wraps Assent's OIDC/Azure strategy with a **tenant-scoped authority** (`https://login.microsoftonline.com/<tenant_id>/v2.0`) and the org's client_id/secret. Fully real (Assent already does OIDC).
- **`SSO.SAML`** — **fully real via `esaml`** (per-org dynamic config). Builds the SP + signed `AuthnRequest` (`authorize_url`), receives the IdP `SAMLResponse`, and **validates the XML signature against the org's `saml_idp_cert`** plus audience, `Conditions`/NotOnOrAfter expiry, and `InResponseTo` (the critical security boundary — reject unsigned/tampered/expired/wrong-audience). Extracts the identity from the assertion (NameID/email). `esaml` is used directly (not Samly) so the IdP metadata/cert are constructed per-request from `org_sso_configs`.

### Per-org config: `org_sso_configs`
```
org_sso_configs
  id            binary_id pk
  organization_id binary_id -> organizations (unique — one SSO config per org this pass)
  protocol      enum [:oidc, :saml]
  email_domain  citext/string   (UNIQUE — routes login; see domain verification)
  domain_verified boolean default false
  enabled       boolean default false
  # OIDC fields (nil for saml)
  oidc_tenant_id, oidc_client_id, oidc_client_secret   (secret = TODO(sso): encrypt at rest)
  # SAML fields (nil for oidc)
  saml_idp_entity_id, saml_idp_sso_url, saml_idp_cert (PEM), saml_sp_entity_id
  timestamps
```
Schema + changeset validate the protocol-appropriate required fields (OIDC requires tenant/client; SAML requires idp_entity_id/sso_url/cert). `Organizations.SsoConfig` (it's org-scoped → lives in/with Organizations, OR a dedicated `Accounts.SSO` context owns it — **decision: a new `SSO` context** owns `org_sso_configs` + the flow, calling `Organizations`/`Accounts` APIs for membership/users; keeps the surface cohesive).

### Login routing + flow (`SSO` context)
- `SSO.config_for_email(email)` → the enabled+verified `org_sso_config` whose `email_domain` matches the email's domain, or nil.
- Login page: user enters email → if `config_for_email` returns a config → `SSO.authorize_url(config)` → redirect to the IdP. Else fall back to password/magic-link (existing).
- Callback (`/sso/:org_or_config/callback` or reuse `/auth/...`): `SSO.sign_in(config, params, session)` → adapter `callback` → identity → **resolve + provision**:
  - Reuse the existing `resolve_identity`/`link_or_create` logic (provider = `"entra:#{org_id}"` or similar so identities are org-scoped), preserving the **verified-email account-link guard** (an unverified asserted email must NOT link to an existing account → prevents takeover).
  - **Then ensure org membership**: add the user to `config.organization_id` (via `Organizations.add_member`, default role) if not already a member. JIT into the org.
  - Returns `{:ok, user}` → the web layer logs them in (`UserAuth.log_in_user`).

### Security (first-class — not deferrable)
1. **Domain verification.** `email_domain` routes login AND gates JIT/linking. An org must **not** be able to claim another org's (or a public, e.g. `gmail.com`) domain — else it could intercept logins / take over accounts by asserting victim emails. So: `email_domain` UNIQUE; routing/JIT only when `domain_verified == true`; a verification step (DNS TXT record check) sets the flag. **This pass: enforce the `domain_verified` gate + a unique constraint + an admin-triggered verification function; the actual DNS-TXT lookup may be a `TODO(sso)` if heavy, but the GATE is enforced (no routing/JIT on an unverified domain).** Block obviously-public domains (gmail/outlook/etc.) from being claimable.
2. **Account-link guard.** Keep the existing rule: only link an SSO identity to an existing user when the asserted email is **verified by the IdP** AND within the org's **verified domain**. Never auto-link a cross-domain or unverified email.
3. **SAML signature.** Validate the IdP signature on every assertion; reject unsigned/expired/wrong-audience. This is the SAML adapter's core; do not ship a SAML path that skips signature validation.
4. **Credential storage.** Per-org OIDC client_secret + SAML certs stored; encryption-at-rest is a shared `TODO(sso)` (consistent with the MFA/webhooks secret TODO). Config management is org-admin gated (reuse `Organizations.admin?`).
5. **CSRF/state.** OIDC `state`/nonce via Assent's `session_params` (already handled); SAML `RelayState` + InResponseTo validated.

### Management surface
- `SSO` context API (org-admin gated via `Organizations.admin?`): `configure_sso(org, scope, attrs)`, `enable_sso/disable`, `verify_domain(org, scope)`, `get_config(org)`.
- **REST**: `GET/PUT /api/orgs/:org_id/sso` (configure/read), OpenAPI-documented; org-admin gated; secrets never returned.
- **LiveView**: an org-admin SSO setup page (protocol, creds/metadata, domain + verify button, enable toggle). Discrete test ids; paper theme. (May be trimmed if the pass is large — see plan.)

### Events
Emit `:"member.provisioned"` (or reuse an existing) on JIT into an org? — Optional; **defer** unless trivial (note as `TODO(sso)`), to keep 3a focused.

## Risk (accepted — SAML is fully real)
**Per-org *dynamic* SAML is the hard part, and we're doing it for real (user decision).** Most Elixir SAML SP libs (Samly) lean on global/static SP config; we use **`esaml` (Erlang) directly** so each request constructs the IdP descriptor (entity_id, SSO URL, signing cert) from `org_sso_configs`. `esaml` provides AuthnRequest generation + `esaml_sp:validate_assertion/…` (XML signature via `xmerl_dsig`/`public_key`, condition/audience checks). The work: a thin `SSO.SAML` adapter that (1) builds an `#esaml_sp{}` per org, (2) generates the redirect/AuthnRequest for `authorize_url`, (3) on callback decodes + **validates** the `SAMLResponse` and maps the assertion → the normalized `identity`. **The plan sequences SAML LAST** (after OIDC + per-org config + routing + JIT are green) so the foundation lands first, but SAML SHIPS REAL this pass — including a negative test that a signature-invalid/expired assertion is rejected. NOTE: `esaml` works on parsed XML (`xmerl`); test with fixture assertions signed by a test key (no live Entra).

## Testing
- `org_sso_configs` schema/changeset: protocol-specific required fields; unique email_domain; public-domain rejection.
- `config_for_email`: matches a verified+enabled domain; ignores unverified/disabled; nil for unknown.
- OIDC flow: with a **Stub `SSO.Provider`** (no real Entra calls — mirror the existing `OAuth.Stub`), `authorize_url` → url; `sign_in` → identity → JIT user + **org membership** created; existing-user verified-email link; unverified-email → not linked.
- Domain-verification gate: SSO on an unverified domain does NOT route/JIT.
- SAML: with the stub/real adapter, a signature-invalid assertion is rejected (if scaffolded, assert the TODO + that the seam returns :not_implemented).
- Management: org-admin can configure/enable/verify; non-admin → unauthorized; secrets not returned (REST).
- Login routing: an SSO-domain email redirects to the IdP; a non-SSO email gets the password/magic-link path.

## Out of scope (this pass — TODO / later)
- **SCIM** (Spec 3b).
- DNS-TXT domain verification automation (gate enforced; the lookup may be a TODO).
- Credential encryption-at-rest (shared TODO with MFA/webhooks).
- Multiple SSO configs per org / multiple domains per org (one each this pass).
- SSO-enforced (disable password login for SSO domains) — note as a follow-up policy.

## Definition of done
- `org_sso_configs` table + schema (protocol-validated, unique verified domain, public-domain block).
- `SSO.Provider` behaviour + OIDC adapter (real, tenant-scoped Entra) + SAML adapter (**real via `esaml`** — signature/assertion validation) + a Stub for tests.
- `SSO` context: config CRUD (org-admin gated), `config_for_email`, `authorize_url`, `sign_in` (reuses resolve_identity guard + adds org membership), `verify_domain` (gate enforced).
- Login routing by email domain; callback wired; JIT provisioning into the org with the verified-email/domain link guard.
- REST config endpoint (OpenAPI; secrets hidden) + (LiveView setup page, scope-permitting).
- Tests green (stubbed IdP — no real Entra calls); `mix precommit` green.

## Open questions
1. ~~SAML real vs scaffold~~ — **RESOLVED: SAML is fully real via `esaml` this pass** (no scaffold).
2. **DNS-TXT domain verification** — enforce the `domain_verified` gate now and implement the actual DNS lookup, or gate-now + `TODO(sso)` the lookup (admin sets verified after an out-of-band check)? Default: enforce the gate; implement a simple DNS-TXT check if light, else TODO.
3. **Management UI depth** — REST + a LiveView setup page, or REST + context API only this pass (UI in a follow-up)? Default: REST + context API solid; LiveView if the pass isn't already too big.
