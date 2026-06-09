# OWASP ASVS 5.0 Full System Audit — PerfectPaper

**Date:** 2026-06-06
**Stack:** Elixir/Phoenix 1.8, LiveView, Bandit, Ecto/Postgres, Oban, enterprise SSO (OIDC/SAML), SCIM 2.0, Teams bot.
**Scope:** `lib/perfect_paper`, `lib/perfect_paper_web`, `config/`.
**Target:** ASVS Level 2 (enterprise paths to Level 3 where noted).

---

## HIGH Severity

### H-1 · Teams bot endpoint: JWT verifier is a no-op stub in production

```
config/config.exs:34 · v5.0.0-4.1.1 · HIGH · V4 API & Web Service ·
  Teams JWT verifier defaults to Stub (accepts every request); no runtime override in runtime.exs.
  Any actor can POST arbitrary Bot Framework Activities to /teams/messages without a valid JWT.
  Fix: implement PerfectPaper.Teams.TokenVerifier.Real with JWKS fetch + signature + iss/aud/serviceUrl
  validation, and configure it via runtime.exs for production (override the compile-time default Stub).
```

Details: `config/config.exs:34` sets `:teams_token_verifier` to `PerfectPaper.Teams.TokenVerifier.Stub`. The Stub returns `{:ok, %{"aud" => "stub-app-id"}}` for every call regardless of the header. `config/runtime.exs` has no override. `teams_controller.ex:32` calls `TokenVerifier.verify/2` — it always succeeds, so every POST to `/teams/messages` proceeds directly into `Teams.handle_activity`. The `@moduledoc` in `token_verifier.ex:8` explicitly flags this: *"The real adapter (JWKS fetch + JOSE verify) is TODO(teams)."*

---

### H-2 · SSO domain verification is self-service — enables account takeover

```
lib/perfect_paper/sso.ex:122-137 · v5.0.0-6.1.2 · HIGH · V6 Authentication ·
  verify_domain/2 stamps domain_verified=true with no DNS-TXT proof; any org admin can claim any
  email domain (e.g. "gmail.com"), enable SSO with a fake OIDC IdP, then trigger Rule 2 in
  resolve_sso_identity (accounts.ex:384-391) to strip a victim's hashed_password + revoke sessions
  and seize their account. Only org-admin access is required.
  Fix: implement DNS-TXT ownership proof before setting domain_verified=true (remove the TODO).
  Also: cap maximum domain claim to orgs' own verified domains; restrict Rule 2 to match only
  domains that pass DNS verification.
```

---

## MED Severity

### M-1 · Remember-me cookie missing `secure` flag in production

```
lib/perfect_paper_web/user_auth.ex:14-18 · v5.0.0-7.3.1 · MED · V7 Session Management ·
  @remember_me_options has no `secure: true`. The session cookie (endpoint.ex:16) correctly sets
  `secure: Mix.env() == :prod` at compile time, but the long-lived 14-day remember-me cookie
  does not inherit this. It is transmitted in plaintext over HTTP if a reverse proxy drops HTTPS.
  Fix: add `secure: Mix.env() == :prod` to @remember_me_options.
```

---

### M-2 · Password-based login POST has no rate limiting

```
lib/perfect_paper_web/controllers/user_session_controller.ex:89-103 · v5.0.0-6.2.2 · MED · V6 Authentication ·
  Magic-link path in UserLive.Login (login.ex:186-193) is rate-limited (5/min IP, 5/hr email).
  The direct POST to /users/log-in (password branch, user_session_controller.ex:89) is not.
  Brute-force with Burp/ffuf against this endpoint is unconstrained.
  Fix: add RateLimit.check/3 calls at the top of the `create/2` password branch, keyed on
  conn.remote_ip and email, with the same windows as the LiveView path.
```

---

### M-3 · MFA declared but never enforced — on_mount(:require_mfa) is a no-op

```
lib/perfect_paper_web/user_auth.ex:276-279 · v5.0.0-6.4.1 · MED · V6 Authentication ·
  Organizations can set mfa_required=true and users can set mfa_enabled=true (accounts.ex:863);
  mfa_required_for?/1 correctly evaluates both. However, on_mount(:require_mfa) at line 276
  unconditionally returns {:cont, socket} — it never challenges. The same gap exists in
  Tokens.user_from_session_token (tokens.ex:43: TODO comment). Until this is wired:
  enterprise customers who believe MFA is enforced are not protected.
  Fix: in on_mount(:require_mfa), check Accounts.mfa_required_for?(user); if true and session
  is not MFA-verified, halt and redirect to the MFA challenge. Mirror the check in Tokens for API.
```

---

### M-4 · REST API has no rate limiting

```
lib/perfect_paper_web/router.ex:134-165 · v5.0.0-4.3.1 · MED · V4 API & Web Service ·
  All /api/* routes run through ApiAuth + UnicodeSanitizer only. No call-rate or burst protection
  exists for any API endpoint (history CRUD, webhook management, SSO config, billing). Hammer is
  available in the project. An API key holder can hammer context functions without throttle.
  Fix: add a RateLimit plug in the :api pipeline (e.g. 60 req/min per key, 200/min per IP),
  or enforce per-route with a before-action helper; return 429 on breach.
```

---

### M-5 · Database SSL disabled in production config

```
config/runtime.exs:74 · v5.0.0-12.1.1 · MED · V12 Secure Communication ·
  `# ssl: true,` is commented out in the Ecto repo config block for production.
  Postgres connections are unencrypted unless the hosting layer independently enforces SSL
  (e.g. RDS enforced mode). All credentials, tokens, and document content transit in plaintext.
  Fix: uncomment `ssl: true` and add `ssl_opts: [cacerts: :public_key.cacerts_get()]` for
  CA verification.
```

---

### M-6 · Webhook multi-org BOLA: silent first-org selection

```
lib/perfect_paper_web/controllers/api/webhook_controller.ex:201-212 · v5.0.0-8.1.1 · MED · V8 Authorization ·
  When a user administers >1 organization and the request has no organization_id param,
  caller_org/1 silently picks the first org returned by Organizations.admin_orgs/1. Webhook
  CRUD operations (create, list, rotate_secret, deliveries) execute against an arbitrarily
  selected org rather than the one the caller intends.
  Fix: require organization_id when the caller is admin of >1 org; return 422 if missing.
  Remove the TODO comment and implement the disambiguation.
```

---

### M-7 · Deactivated-user check missing from LiveView socket mount path

```
lib/perfect_paper_web/user_auth.ex:300-309 · v5.0.0-7.1.2 · MED · V7 Session Management ·
  mount_current_scope/2 calls Accounts.get_user_by_session_token/1 without checking
  deactivated_at. The HTTP pipeline (fetch_current_scope_for_user, line 71) correctly gates
  on `is_nil(user.deactivated_at)`. If token deletion in deactivate_user/1 races with a
  concurrent LiveView reconnect (e.g. rapid SCIM deprovisioning + active tab), a deactivated
  user may briefly hold a valid LiveView session.
  Fix: add `true <- is_nil(user.deactivated_at)` to the with chain in mount_current_scope,
  mirroring the HTTP path. Defense-in-depth with the token-deletion primary gate.
```

---

## LOW Severity

### L-1 · CSP `unsafe-inline` for scripts on API docs page

```
lib/perfect_paper_web/router.ex:74 · v5.0.0-3.4.2 · LOW · V3 Web Frontend ·
  The :docs pipeline sets script-src 'self' 'unsafe-inline'. This disables browser-enforced
  script injection protection for /api/docs. Redoc requires it for its init script.
  Fix: generate a per-request nonce, pass it to the CSP header and the inline <script> block,
  removing 'unsafe-inline'. Alternatively use a CDN SRI hash for the Redoc bundle.
```

---

### L-2 · `Phoenix.HTML.raw` on nav icon source

```
lib/perfect_paper_web/components/app_shell.ex:156 · v5.0.0-1.1.1 · LOW · V1 Encoding & Sanitization ·
  {Phoenix.HTML.raw(item.icon)} renders SVG strings without escaping. Currently the icon source
  is developer-controlled (static tuples), so no current XSS. If the nav definition is ever
  derived from DB/user data, this becomes an XSS vector.
  Fix: document a strict invariant that icon values must be compile-time literals, or wrap with
  Phoenix.HTML.sigil_H to enforce Phoenix's escaping on any string-to-render path.
```

---

### L-3 · `String.to_atom` on a map key from cookie data

```
lib/perfect_paper/compliance.ex:159 · v5.0.0-15.3.1 · LOW · V15 Secure Coding ·
  `defp get(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))` is called
  on cookie-consent preference keys. Input is from a signed cookie (can't be tampered with)
  but the pattern is risky if the input source ever changes to raw HTTP params.
  Fix: use `String.to_existing_atom/1` to limit to pre-declared atoms, or use only string
  keys throughout the consent map.
```

---

### L-4 · No `Cache-Control: no-store` on sensitive authenticated responses

```
lib/perfect_paper_web/router.ex (general) · v5.0.0-14.1.1 · LOW · V14 Data Protection ·
  Authenticated LiveView pages (workspace, history, billing) do not set Cache-Control: no-store.
  Shared/public computers may cache review content, billing details, or credentials in the
  browser disk cache.
  Fix: add a plug in the :browser pipeline (or in the :require_authenticated_user scope) that
  sets `put_resp_header(conn, "cache-control", "no-store, private")` on HTML responses.
```

---

### L-5 · No `sobelow` or `mix_audit` in toolchain

```
mix.exs (deps) · v5.0.0-13.5.1 · LOW · V13 Configuration ·
  Neither `sobelow` (Phoenix static security scanner) nor `mix_audit` (advisory DB check for
  deps) is listed as a dev dependency. Known vulnerability detection depends on manual process.
  Fix: add `{:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}` and
  `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` and run them in CI.
```

---

### L-6 · Hardcoded session signing salts committed to source

```
lib/perfect_paper_web/endpoint.ex:12, config/config.exs:65 · v5.0.0-13.2.1 · LOW · V13 Configuration ·
  signing_salt: "vABGqwEU" (cookie store) and live_view: [signing_salt: "0I/E+hBI"] are
  committed to source for all environments. Security depends on SECRET_KEY_BASE remaining
  secret; if SKB is ever rotated, these salts can't be individually rotated.
  Fix: load signing salts from environment variables in runtime.exs (same as secret_key_base).
```

---

### L-7 · No security event logging for credential operations

```
lib/perfect_paper/accounts.ex (update_user_password, deactivate_user) · v5.0.0-16.1.1 · LOW · V16 Logging ·
  Password changes, account deactivations, SCIM provisioning, and SSO squatter-neutralization
  have no structured security-event log emission. authz_decisions table (authz.ex:135) logs
  mutating AuthZ decisions, but authentication operations do not feed a security log.
  Fix: emit Events.emit(:"account.password_changed", ...) and :"account.deactivated" after
  each sensitive operation, and ensure those events have an audit-log consumer.
```

---

## ASVS Coverage Table

| Chapter | Status |
|---|---|
| **V1** Encoding & Sanitization | Audited — 1 LOW (raw SVG in nav) |
| **V2** Validation & Business Logic | Audited — clean; FKs set from scope, not cast from params |
| **V3** Web Frontend | Audited — 1 LOW (CSP unsafe-inline on docs); LiveView XSS surface clean |
| **V4** API & Web Service | Audited — 1 HIGH (Teams stub), 1 MED (no REST rate limit) |
| **V5** File Handling | Audited — allow_upload uses Phoenix validated path; Panpipe runs in Exile child process; no path traversal found |
| **V6** Authentication | Audited — 1 HIGH (SSO domain proof), 1 MED (password brute-force), 1 MED (MFA unimplemented) |
| **V7** Session Management | Audited — 1 MED (remember-me cookie secure flag), 1 MED (deactivated-user race) |
| **V8** Authorization | Audited — 1 MED (webhook BOLA); ownership always in WHERE clause; 404/403 semantics correct via Authz |
| **V9** Self-contained Tokens | Not Applicable — app issues opaque random tokens, no JWTs. Inbound Teams JWT covered under V4/V6 |
| **V10** OAuth & OIDC | Audited — Assent handles state/PKCE; redirect_uri derived from config; SSO domain gap covered under V6/H-2 |
| **V11** Cryptography | Audited — Bcrypt passwords; SHA-256 email/SCIM/API-key tokens; raw bytes for session tokens (phx.gen.auth pattern); `:crypto.strong_rand_bytes` throughout; no MD5/SHA-1/ECB found |
| **V12** Secure Communication | Audited — force_ssl + HSTS in prod.exs; 1 MED (DB SSL commented out); outbound Req uses OTP TLS defaults; no verify: :verify_none found |
| **V13** Configuration | Audited — secrets in runtime.exs, not committed; 1 LOW (sobelow/mix_audit missing); 1 LOW (signing salts hardcoded) |
| **V14** Data Protection | Audited — 1 LOW (no Cache-Control: no-store); no PII in logs found |
| **V15** Secure Coding | Audited — 1 LOW (String.to_atom); all SQL via parameterized Ecto fragments; no Code.eval/binary_to_term |
| **V16** Logging & Error Handling | Audited — 1 LOW (no security event log for auth ops); authz_decisions table exists |
| **V17** WebRTC | Not Applicable — no WebRTC in stack |

---

## Totals

| Severity | Count |
|---|---|
| HIGH | 2 |
| MED | 6 |
| LOW | 7 |
| **Total** | **15** |

---

## Top 5 Fixes (Priority Order)

1. **[H-1] Implement the real Teams JWT verifier.** The `/teams/messages` endpoint is completely open. Any actor can inject arbitrary Activities (link-token messages, notification triggers). Implement JWKS fetch + JOSE verification and wire it in `runtime.exs` for prod before this feature goes live.

2. **[H-2] Add DNS-TXT proof to SSO domain verification.** Self-service domain claiming enables full account takeover via Rule 2 squatter neutralization. Block `enable_sso` if `domain_verified` was set without DNS proof. This is the highest-impact misconfiguration a legitimate org admin can trigger.

3. **[M-2] Rate-limit the password POST at `/users/log-in`.** The LiveView magic-link path is protected; the direct controller POST is not. Add a `RateLimit.check/3` call at the top of `UserSessionController.create` using the same buckets as `Login.rate_limited?/2`.

4. **[M-5] Enable database SSL.** Uncomment `ssl: true` in `runtime.exs` and add `ssl_opts` with CA verification. All user data, tokens, and document content are currently transmitted to Postgres in plaintext.

5. **[M-3] Enforce MFA where required.** The `mfa_required_for?/1` predicate and org-level `mfa_required` flag exist but are never acted on. Wire up the partial-session halt in `on_mount(:require_mfa)` and in `Tokens.user_from_session_token` before marketing this to enterprise customers as an MFA-capable product.

---

## Cross-Seam Audit

> Siloed auditors each read their chapter in isolation. This section re-reads the same findings through the lens of *how subsystems interact* — chains, races, and amplifications that only appear when two or more silo findings compose.

### What was verified vs assumed

All seam findings below were confirmed against the source before being written. Specifically:

- `SSO.sign_in` **does** call `ensure_not_deactivated/1` at sso.ex:229 after `resolve_sso_identity` — SCIM deprovision + SSO re-login is **blocked**. (This was a concern; it is NOT a finding.)
- `Webhooks.dispatch` correctly scopes delivery by `event.organization_id` at webhooks.ex:47 — the M-6 BOLA does **not** cause cross-org event delivery. (M-6 is limited to webhook management CRUD.)
- `Tokens.user_for_bearer` **does** check `deactivated_at` at tokens.ex:28 — API keys and session bearer tokens are rejected for deactivated users. (Correct. The gap is LiveView mount only, per M-7.)
- `deactivate_user/1` at accounts.ex:464 deletes `users_tokens` and revokes API keys — but does **not** delete `teams_links` rows.
- `reply_status` at teams.ex:134 calls `Accounts.get_user!(link.user_id)` with no `deactivated_at` check and no guard on link staleness.

---

### S-H1 · H-1 × Teams account linking — notification hijack + session enumeration (HIGH)

```
lib/perfect_paper/teams.ex:92-108, 128-143 · v5.0.0-4.1.1 × v5.0.0-8.1.1 · HIGH ·
  V4 API × V8 Authorization ·
  Because H-1 (JWT stub) accepts any POST to /teams/messages, an attacker can send a
  conversationUpdate Activity with an arbitrary aad_object_id. Two consequences compose:

  (1) link_from_activity (line 92): upsert_link/1 updates the conversation_reference for
  the matching teams_links row. An attacker who knows a victim's AAD OID can redirect all
  future push notifications (session complete, comment added) to their own Teams conversation.
  This is a persistent notification hijack with no credential required beyond knowing the OID.

  (2) reply_status (line 128): sends back the linked user's last 5 session titles and states.
  With H-1, an attacker can enumerate any linked user's recent work history by POSTing a
  "status" message Activity with their AAD OID.

  Root cause: H-1 removes the only authentication gate on /teams/messages. These two handlers
  then act on untrusted aad_object_id without any secondary ownership check.
  Fix: fix H-1 first (real JWT verifier). As defense-in-depth, add a tenant_id consistency
  check in link_from_activity: reject any Activity whose tenant_id doesn't match the org's
  oidc_tenant_id from SsoConfig.
```

---

### S-H2 · H-2 × H-1 — domain squatting amplifies to Teams notification takeover (HIGH)

```
lib/perfect_paper/sso.ex:122-137 × lib/perfect_paper/teams.ex:92-108 ·
  v5.0.0-6.1.2 × v5.0.0-4.1.1 · HIGH · V6 Authentication × V4 API ·
  H-2 (self-service domain verification) allows account takeover of victim@victim.com.
  H-1 (Teams JWT stub) allows arbitrary aad_object_id injection into Teams activities.
  When chained:
  1. Attacker seizes victim@victim.com via H-2 (Rule 2 squatter neutralization).
  2. Victim's teams_links row (conversation_reference) still exists under the original account.
  3. Attacker uses H-1 to POST a conversationUpdate with the victim's AAD OID, rewriting the
     conversation_reference to the attacker's channel.
  4. All future Teams notifications for the victim's (now attacker-controlled) account land
     in the attacker's Teams client.
  The two HIGHs are individually severe; chained they yield persistent, silent exfiltration
  of both account access and notification stream.
  Fix: fix H-1 and H-2 independently — neither has a cross-seam-only fix.
```

---

### S-M1 · M-3 (MFA no-op) × SSO — amr/acr claim not validated; zero-factor path for SSO orgs (MED)

```
lib/perfect_paper_web/user_auth.ex:276-279 × lib/perfect_paper/sso/oidc.ex:112 ·
  v5.0.0-6.4.1 × v5.0.0-10.2.4 · MED · V6 Authentication × V10 OAuth/OIDC ·
  Orgs can set mfa_required=true (Accounts.mfa_required_for?/1 is correct). But:
  - on_mount(:require_mfa) is a no-op (M-3) — no challenge issued in the web layer.
  - The OIDC adapter (sso/oidc.ex) validates state/nonce via Assent but does NOT inspect
    the `amr` or `acr` claims on the returned ID token. Even if the IdP asserts amr=["pwd"]
    (password-only, no second factor), sign_in/3 succeeds.
  Combined: an enterprise org that believes MFA is enforced gets no MFA challenge from either
  the web layer OR the SSO callback. A phished SSO credential grants full access. M-3's
  severity as a standalone finding (web layer) is elevated by the OIDC layer also being silent.
  Fix: in SSO.sign_in, after Assent callback, check id_token claims for amr/acr when
  Accounts.mfa_required_for?(user) returns true. Reject with {:error, :mfa_required} if the
  IdP did not assert a second factor. This is independent of fixing M-3 (the web-layer path).
```

---

### S-M2 · SCIM deprovisioning × Teams links — stale link leaks post-deactivation data (MED)

```
lib/perfect_paper/accounts.ex:458-469 × lib/perfect_paper/teams.ex:128-143 ·
  v5.0.0-7.1.2 × v5.0.0-14.1.1 · MED · V7 Session × V14 Data Protection ·
  deactivate_user/1 deletes users_tokens and revokes API keys but does NOT delete teams_links
  rows (confirmed: no mention of Teams in deactivate_user or its callers).
  Consequences:
  (1) Oban TeamsNotifier workers fire against all teams_links rows for the user's user_id. A
      deprovisioned employee continues to receive Teams push notifications (session complete,
      comment added) about the org's work until the link row is manually deleted. GDPR/SCIM
      spec requires cessation of all data flows to a deprovisioned identity.
  (2) reply_status (teams.ex:134) calls Accounts.get_user!(link.user_id) with no
      deactivated_at check. If H-1 is fixed with real JWT validation, a still-active Teams
      user at the same tenant could query a deprovisioned colleague's session list if they
      learn the victim's AAD OID (e.g. from AAD directory listing).
  Fix: in deactivate_user/1, add
    Repo.delete_all(from l in PerfectPaper.Teams.Link, where: l.user_id == ^user.id)
  Also add a deactivated_at guard in reply_status before building the scope.
```

---

### S-M3 · H-2 × M-4 (no API rate limit) — account seizure enables credit-pool drain (MED)

```
lib/perfect_paper/sso.ex:122-137 × lib/perfect_paper_web/router.ex:134-165 ·
  v5.0.0-6.1.2 × v5.0.0-4.3.1 · MED · V6 Authentication × V4 API ·
  H-2 (domain squatting) enables silent account takeover of any existing user whose email
  matches the claimed domain. The seized account retains its org memberships, including shared
  credit pools. M-4 (no API rate limiting) means an attacker with the victim's session token
  can call POST /api/sessions in a tight loop without throttle.
  Chained: an attacker who exploits H-2 gains an account with org credit access, then uses M-4
  to drain the victim org's credit pool (append-only credit_events ledger; balance goes to zero
  or deep negative) before the breach is detected.
  Fix: fix H-2 to prevent the initial account seizure. Fix M-4 independently to cap session
  creation rate per API key. Neither fix alone stops the chain — both are required.
```

---

### S-L1 · L-7 (no security event log) × all auth seams — breach detection is blind (LOW)

```
lib/perfect_paper/accounts.ex (deactivate_user, resolve_sso_identity, neutralize_squatter_and_link) ·
  v5.0.0-16.1.1 · LOW · V16 Logging ·
  L-7 (no structured security-event log) means none of the cross-seam exploit chains above
  produce a detectable signal:
  - H-2 exploitation (domain verification + SSO sign-in as a different user) leaves no audit trail.
  - S-H1 (Teams notification hijack via AAD OID injection) generates no log entry.
  - S-M2 (deprovisioned user receiving Teams notifications) is silent.
  - Rule 2 squatter neutralization (password nullification, session revocation) is not logged.
  Without event emission on these operations, incident response has no timeline to work from.
  Fix: emit Events.emit/2 after neutralize_squatter_and_link, domain_verified mutation, and
  any SSO sign-in. Ensure an audit-log consumer persists these events.
```

---

---

### S-M4 · SCIM.reactivate_user discards Accounts.reactivate_user result — billing fires for an unrecoverable user (MED)

```
lib/perfect_paper/scim.ex:141-148 · v5.0.0-16.1.1 × v5.0.0-2.1.1 · MED · V16 Logging × V2 Validation ·
  SCIM.reactivate_user (scim.ex:138) calls:
    if user && user.deactivated_at, do: Accounts.reactivate_user(user)
  The return value of Accounts.reactivate_user/1 is discarded. If the DB update
  fails (transient error, constraint, or changeset failure), the if-expression
  returns nil and the code continues to Events.emit(:"member.reactivated", ...).
  Consequences:
  1. Membership is marked active (Organizations.reactivate_membership succeeded).
  2. Events.emit fires: SeatTrackerServer calls Billing.bump_peak_seats_for_event,
     raising billing high-water for a user who cannot actually log in.
  3. SCIM GET /Users/:id returns active=true (membership row is active).
  4. The user's deactivated_at is still set — fetch_current_scope_for_user and
     Tokens.user_for_bearer both reject them. They cannot log in until the issue
     is manually detected and fixed.
  The state is silently inconsistent: billing counts the user as a seat, the SCIM
  API reports them as active, but login is blocked and no alert is emitted.
  Fix: use `with {:ok, _} <- Accounts.reactivate_user(user)` or explicitly check
  the result and return {:error, reason} on failure. Let the SCIM controller
  propagate a 500 so Entra retries rather than considering the operation complete.
```

---

---

### S-H3 · H-2 × auto-link for confirmed users — silent identity binding, no session revocation (HIGH)

```
lib/perfect_paper/accounts.ex:367-393 × lib/perfect_paper/sso.ex:122-137 ·
  v5.0.0-6.1.2 × v5.0.0-10.2.1 · HIGH · V6 Authentication × V10 OAuth/OIDC ·
  H-2 (domain claiming without DNS proof) was described as reaching Rule 2 in
  link_or_create (accounts.ex:384-391), which strips the victim's password and
  revokes their sessions — detectable. But the cond chain has a more dangerous
  FIRST branch (line 376):

    verified && user.confirmed_at != nil -> link_identity(user, identity)

  This fires for ANY confirmed user whose email domain matches the attacker's
  claimed domain. A fake OIDC IdP asserts email_verified: true (the IdP is
  attacker-controlled, so this is trivial). The attacker's OIDC identity is
  silently inserted into the victim's user_identities rows via link_identity/2.
  No password is changed. No sessions are revoked. No notification is sent.

  Impact vs Rule 2:
  - Rule 2 applies only when confirmed_at IS nil AND hashed_password != nil
    (unconfirmed users who set a password). Condition 1 applies to all
    confirmed users — the much larger population.
  - Rule 2 is detectable (victim loses sessions, notices they can no longer log
    in with password). Condition 1 is invisible until the victim audits their
    linked identities.
  - Attacker retains persistent, silent SSO access indefinitely unless the
    victim manually checks and removes the linked identity.

  For platform-admin emails: silent binding grants the attacker platform admin
  access (RequirePlatformAdmin, /admin/* LiveViews) without any indication
  to the legitimate admin.

  Fix: the DNS proof requirement (H-2 fix) removes the premise. As defense-in-
  depth, auto-link (condition 1) should require that the binding org's SSO config
  is enabled AND that the identity's issuer matches the org's oidc_tenant_id, not
  just email_verified from the IdP. Notify the user (email) when a new identity
  provider is linked to their account.
```

---

## Convergence Check (Round 2)

The second seam pass investigated the following additional intersections and found them safe:

- **`History.ReviewWorker` + Credits double-charge**: Oban `unique` on `[:session_id]` across ALL states (including `completed`) guarantees one job per session. `process_session/2` has its own idempotency guard (line 131: checks `processing_status == :complete` before proceeding). Double-charge on Oban retry is **not possible**. **Not a finding.**
- **`Documents.export/2` format injection**: The `format` param (from URL) is validated via `Map.fetch(@export_formats, format)` against a fixed compile-time map of three strings. No `String.to_atom`, no shell exec. **Not a finding.**
- **`ExportController` document scope**: `document_id` comes from the already-scoped `session` row, not from user input. `Documents.get_document/1` is unscoped but the authorization chain is complete at the session level. **Not a finding.**
- **`Authz.load_subject/1` + deactivated_at in API path**: `load_subject` is only called after `ApiAuth` sets `current_user` via `Tokens.user_for_bearer`, which calls `ensure_active/1` checking `deactivated_at`. No gap. **Not a finding.**
- **`SCIM.provision_user` Events.emit timing**: `Events.emit` is called after the `with` chain succeeds (post all DB writes), not inside any transaction. The `member.provisioned` event fires only on full success. Correct per the CLAUDE.md post-commit rule. **Not a finding.**
- **Referrals double-claim**: `Credits.run_campaign` uses `granted_before?` + `locked_insert` (per-user advisory lock) for dedup. A stray double-`dispatch(:referral_accepted, ...)` cannot double-reward the referrer. **Not a finding.**
- **`Teams.unlink/1` existence but non-call on deactivation**: Confirmed. The function exists at teams.ex:40 but is not called from `Accounts.deactivate_user/1`. This underpins S-M2 (already recorded in Round 1).

---

## Convergence Check (Round 3)

The third pass investigated the following additional intersections:

- **`RequirePlatformAdmin` plug implementation**: confirmed correct — reads `admin_emails` from env, checks downcased email, halts with 403. Billing admin write routes (`configure`, `activate`, `mark_paid`, `void`) ARE behind this plug (router.ex:169). Not a finding.
- **Teams deep-link token (`/teams/link`)**: Phoenix.Token.verify with max_age + `@link_salt`, tenant-consistency check via `check_tenant_consistency`. Route is behind `:browser, :require_authenticated_user`. Token is single-purpose (carries only Teams identity, redeemed by the logged-in user). Not a finding.
- **Admin routes (`/admin/credits`, `/admin/billing`)**: double-gated — `pipe_through [:browser, :require_authenticated_user]` at router + `on_mount :require_admin` in live_session (checks email in admin_emails). Not a finding.
- **`Chatbot.put_prompt_layer/4`**: context function has no built-in authz; relies entirely on call sites (OrgReviewSettingsLive checks admin?, UserLive.Settings uses own user.id). No API endpoint exposes this directly. Not a finding.
- **SAML callback replay protection**: `sso_requests` session map is keyed by org_id and deleted before processing — single-use, per-org. Not a finding.
- **`History.set_visibility`**: correctly gates on `Authz.permit?(scope, :share, session)` which requires `:admin` role. Not a finding.
- **`invite_role` ceiling**: only maps to `:viewer/:commenter/:editor`; `:admin` and `:owner` are unreachable via the invite API. Not a finding.
- **`admin_emails` config**: loaded from `ADMIN_EMAILS` env in runtime.exs, defaulting to `[]` (fail-closed). Not a finding.
- **`H-2 × link_or_create` condition 1**: auto-link for confirmed + verified-email users — CONFIRMED AS NEW HIGH S-H3 above. The Rule 2 path described in H-2 is a secondary path; condition 1 fires first for most users.

---

## Convergence Check (Round 4)

The fourth pass targeted "ticky-tacka" and cross-cutting issues — subtle interactions not caught by any single-chapter or obvious two-system chain.

### New findings from Round 4

---

### S-M5 · IP-based rate-limit bucket uses spoofable XFF first-hop (MED)

```
lib/perfect_paper_web/client_metadata.ex:32-38 · v5.0.0-6.2.2 · MED · V6 Authentication ·
  client_ip/1 uses the FIRST value of the X-Forwarded-For header as the IP bucket key
  for all LiveView rate-limit checks (login.ex:190, registration.ex:320).
  X-Forwarded-For is fully attacker-controllable — a client can send any value. By
  rotating fake IPs (X-Forwarded-For: 1.2.3.4, then 1.2.3.5, etc.) an attacker
  bypasses the per-IP limit (5 auth submissions per 60 seconds) entirely while the
  per-email limit (5 per hour) still applies. This allows low-rate credential stuffing
  across many accounts from a single machine without hitting the IP bucket.
  Fix: use the actual TCP peer address (peer_data.address) as the primary bucket key —
  this is the address of the trusted reverse proxy and cannot be spoofed. Optionally
  apply RemoteIp library with the known proxy count to extract the real client IP from
  a trusted XFF chain.
```

---

### S-L2 · SCIM deactivation orphans GroupMembership rows — amplifies S-M4 (LOW)

```
lib/perfect_paper/scim.ex:111-132 × lib/perfect_paper/authz.ex:95-119 ·
  v5.0.0-8.1.1 · LOW · V8 Authorization ·
  SCIM.deactivate_user/2 revokes explicit resource grants (Authz.revoke_user_grants_in_org)
  and deactivates the org membership, but does NOT delete GroupMembership rows for the user.
  As long as deactivated_at is set (primary login gate) this is inert — group_role/2 in
  authz.ex queries GroupMembership directly with no deactivated_at filter, so the orphaned
  rows are present but unreachable.
  Amplifies S-M4: if SCIM later calls reactivate_user and the S-M4 bug (result discarded)
  partially succeeds — org membership reactivated, deactivated_at NOT cleared — the
  GroupMembership rows remain, ready to re-grant access to all group-owned sessions the
  moment any code path clears deactivated_at (manual DB fix, future reactivation retry).
  Group-based access is restored without any explicit re-grant audit trail.
  Fix: in SCIM.deactivate_user, also delete GroupMembership rows for the user within the
  org: Repo.delete_all(from gm in GroupMembership, join: g in Group, on: gm.group_id == g.id,
  where: gm.user_id == ^user_id and g.organization_id == ^org_id).
  On reactivation, rely on the next SCIM group sync to restore group memberships rather
  than preserving orphaned rows.
```

### Round 4 — confirmed safe

- **SCIM group sync × ltree cross-tenant access**: `set_group_members` (orgs.ex:177-183) filters by `m.organization_id == ^org_id and m.status == :active` before inserting any GroupMembership row. A SCIM token can only add users who are already active members of that org. Cross-tenant group-path injection is **not possible**. **Not a finding.**
- **Monthly credit grant race (subscription.updated × plan change)**: `grant_monthly_allowance/3` uses `locked_insert` with idempotency key `"monthly_allowance:#{period}"` (calendar month). Multiple events in the same month return `:already_granted`. No double-grant. **Not a finding.**
- **`compliance.ex String.to_atom` (L-3 re-investigation)**: `get/2` is only called with hardcoded literal strings (`"version"`, `"analytics"`, `"marketing"`, `"region"`, `"decided_at"`), not external input. Atom table exhaustion is not possible via this path. The existing L-3 silo finding overstates risk; the pattern is safe as written. **Severity should be considered informational only.**

---

## Final Totals

| Severity | Silo findings | Seam R1 findings | Seam R2 findings | Seam R3 findings | Seam R4 findings | Total |
|---|---|---|---|---|---|---|
| HIGH | 2 | 2 | 0 | 1 | 0 | **5** |
| MED | 6 | 3 | 1 | 0 | 1 | **11** |
| LOW | 7 | 1 | 0 | 0 | 1 | **9** |
| **Grand total** | **15** | **6** | **1** | **1** | **2** | **25** |

Round 4 returned 1 MED and 1 LOW. The curve is 6 → 1 → 1 → 2. Round 4 finding rate (2) is below Round 1 (6) but slightly above Round 3 (1), reflecting that Round 4 specifically targeted "ticky-tacka" and cross-cutting issues rather than obvious chains. Both findings were previously un-seen angles on existing infrastructure (rate-limit bypass on the XFF path; orphaned GroupMembership amplifying S-M4). No new HIGH was found. **Audit is converged.**

### All seams investigated and found safe (complete list)

- **SCIM deprovision + SSO re-login**: `SSO.sign_in` calls `ensure_not_deactivated/1` after `resolve_sso_identity`. **Not a finding.**
- **Webhook BOLA (M-6) + cross-org event delivery**: `Webhooks.dispatch` scopes delivery by `event.organization_id`; BOLA only affects management CRUD. **Not a finding.**
- **API bearer path + deactivated user**: `Tokens.user_for_bearer` checks `deactivated_at` via `ensure_active/1`. **Not a finding.**
- **ReviewWorker + Credits double-charge**: Oban unique + process_session idempotency guard. **Not a finding.**
- **Documents.export format injection**: fixed compile-time allowlist. **Not a finding.**
- **ExportController document scope**: session-gated document_id, not user-supplied. **Not a finding.**
- **Authz.load_subject + deactivated_at**: ApiAuth ensures active user before load_subject runs. **Not a finding.**
- **SCIM.provision_user Events.emit timing**: post-all-writes, not inside transaction. **Not a finding.**
- **Referrals double-claim**: campaign dedup via granted_before? + advisory lock. **Not a finding.**
- **SCIM group sync × ltree cross-tenant**: set_group_members filters by org_id + active status. **Not a finding.**
- **Monthly credit grant race**: locked_insert + period idempotency key prevents double-grant. **Not a finding.**
- **compliance.ex String.to_atom**: called only with hardcoded literal keys, not user input. **Not a finding (L-3 overstated).**

---

## Convergence Check (Round 5) — The Elephant Pass

Round 5 applied a deliberate adversarial resampling: instead of re-examining named subsystems (SSO, SCIM, Teams, Credits) through the same interaction pairs, it sampled from un-named substrates — the registration flow's relationship to credit eligibility, the workspace field that carries trust across disconnected requests, the PubSub message that triggers a re-fetch without sanitizing the trigger payload, the comment parent that crosses session boundaries, the SCIM token verifier that applies a timing-safe comparison to a value it already retrieved by exact equality.

### Round 5 — confirmed safe (new angles)

- **`active_workspace_id` trust**: `default_workspace/1` calls `Workspaces.get_workspace(id, user)` which scopes by `user_id`; an inaccessible `active_workspace_id` falls back to personal workspace. **Not a finding.**
- **Public session read path**: No anonymous route serves `is_public: true` sessions. `get_session/2` always requires a Scope; `is_public` is schema-ready infrastructure with no current unauthed access path. **Not a finding — safer than the flag implies.**
- **`act_on_comment` cross-session IDOR**: The comment lookup at history.ex:487 binds both `comment_id` AND `session_id` — a user cannot dismiss a comment from another session by guessing its ID. **Not a finding.**
- **`add_comment` parent_id cross-session**: `validate_parent/2` at history.ex:526-531 scopes the parent comment to the same session_id before allowing the reply. **Not a finding.**
- **PubSub broadcast injection into ReadingRoomLive**: All broadcasts to `"document:..."` originate from server-side conversion workers; the message triggers a DB re-fetch from the server's own session assign, not user-supplied content. **Not a finding.**
- **Ecto fragments SQL injection**: All six fragment uses in the codebase use parameterized bindings (`^variable`), no string interpolation. **Not a finding.**
- **SCIM filter parser**: Values extracted from the Entra filter string go into Ecto parameterized queries; the parser uses a fixed allowlist of three attribute names. **Not a finding.**
- **Magic link single-use**: `login_user_by_magic_link` deletes the specific clicked token on use (line 757: `Repo.delete!(token)`); 15-minute window enforced at DB level. **Not a finding.**
- **`register_user_with_password` missing email in dispatch**: This path is not exposed via any web route; unreachable by external actors. **Not a finding (unexposed).**

### Round 5 — informational (not actionable as security findings)

- **`scim.ex:59` redundant secure_compare**: `Plug.Crypto.secure_compare(hashed, stored)` compares the token hash to itself because the preceding `Repo.get_by(token_hash: hashed)` can only return a row where `stored == hashed`. The `else` branch is structurally unreachable. The DB lookup is the actual gate; this is dead code rather than a vulnerability. Worth a code cleanup note but not a security finding.
- **Academic signup credit reusable via email change**: `signup_preview` dedup key is `"signup_bonus:#{user_id}"` (per-user, not per-email). A user who claimed the credit, changed their email away from an academic address, and then registered a NEW account with the same academic email would get a second credit (new user_id = new dedup key). Requires legitimate academic email access, multi-step effort, and yields exactly 1 additional preview credit. Product design gap, not an attack.

### Final convergence verdict

| Round | New security findings | Cumulative |
|---|---|---|
| Silo (16 chapters) | 15 | 15 |
| Seams R1 | 6 | 21 |
| Seams R2 | 1 | 22 |
| Seams R3 | 1 | 23 |
| Seams R4 | 2 | 25 |
| **Seams R5** | **0** | **25** |

**Audit is converged.** Round 5 investigated substrates and interaction patterns explicitly not examined in prior rounds — registration flows, workspace trust, comment boundary checks, PubSub injection surface, SCIM token internals, Ecto fragment safety — and found zero new security issues. The finding rate has dropped to zero. Final count: **5 HIGH · 11 MED · 9 LOW = 25 total findings.**

---

## Dark Dimensions Audit — Independent Oracle Pass (2026-06-07)

**Objective:** Replace code-reading-plus-reasoning with independent oracles capable of contradicting prior conclusions. Code-reading is the same faculty that produced the code; it is not an independent checker. Each dimension below used a tool or execution that could produce a result different from what reasoning predicts.

### Dimension map

| Dimension | Oracle | Status |
|---|---|---|
| Compiler / type system | `mix compile --warnings-as-errors --force` | ✅ LIT |
| Dependency advisories | `mix hex.audit` | ✅ LIT |
| Interleaving (concurrency) | Real Postgres advisory lock + OS scheduler | ✅ LIT |
| Assertion quality | Manual mutation testing | ✅ LIT — **CRITICAL GAP FOUND** |
| Time (token expiry) | Existing test suite (back-date inserted_at) | ✅ LIT |
| Failure injection | Code path analysis (Events.dispatch nil-org short-circuits) | ◑ PARTIAL |
| Scale / N+1 | Query inspection | ◑ PARTIAL |
| Property / input generation | No StreamData installed | ⬛ DARK |
| Environment (deploy config) | Not run | ⬛ DARK |

---

### Oracle 1: Compiler — `mix compile --warnings-as-errors --force`

**Result: CLEAN.** 215 modules compiled, zero warnings-as-errors. The Elixir type system and compiler found nothing.

---

### Oracle 2: Dependency advisories — `mix hex.audit`

**Result: CLEAN.** No retired or security-flagged packages. Supply chain dimension is clear.

---

### Oracle 3: Interleaving — concurrent credit charge stress test

The advisory lock `pg_advisory_xact_lock` is held at the outer Postgres `BEGIN` level, not at the `SAVEPOINT` level used inside Ecto's sandbox mode. To exercise real concurrency, the test switches to `:auto` pool mode (real `COMMIT`/`ROLLBACK`) so multiple processes get genuinely separate Postgres transactions.

**Test:** 20 concurrent `charge_for_proofreading` calls against a user with 3 credits.
**Oracle:** Postgres advisory lock + OS scheduler arbitrate among 20 real concurrent transactions.
**Result: CLEAN.** Exactly 3 charges succeeded, 17 returned `{:error, :insufficient_credits}`, final balance = 0. No double-spend.

**File:** `test/perfect_paper/credits_concurrency_test.exs`

---

### Oracle 4: Assertion quality — manual mutation testing

**Method:** Remove the most critical correctness mechanism, run the test suite, verify the tests detect it.

#### Mutation A: Remove advisory lock from `charge/3`

Removed the `Ecto.Multi.run(:lock, ...)` step from `charge/3`.

**Control oracle — existing tests:** `mix test test/perfect_paper/credits_test.exs` → **33 tests, 0 failures.** The existing suite does NOT detect the removal of the advisory lock.

**Concurrency oracle:** `mix test test/perfect_paper/credits_concurrency_test.exs` → **FAIL.** Message: `DOUBLE-SPEND: 19 charges succeeded but only 3 credits existed.` The Postgres READ COMMITTED level let all 20 tasks see balance=3 simultaneously; 19 inserted successfully. Final balance: -16.

#### Mutation B: Remove advisory lock from `locked_insert`

Removed `lock_user(Repo, user_id)` from `locked_insert/3`.

**Control oracle — existing tests:** `mix test test/perfect_paper/credits_test.exs` → **33 tests, 0 failures.** Unchanged. The sequential idempotency tests pass because they call the function twice from the same process — the `already?.()` check catches serial duplicates, but not concurrent ones.

**Concurrency oracle:** `mix test test/perfect_paper/credits_concurrency_test.exs` → **FAIL.** Message: `DOUBLE-GRANT: 3 allowances inserted for one period.` Without the lock, 3 concurrent tasks raced through `already?.() = false` before any insert committed.

#### Summary of assertion quality findings

**CRITICAL GAP:** The advisory lock in both `charge/3` and `locked_insert` — the sole mechanism preventing double-spend and double-grant — is completely invisible to the 33-test existing credit suite. All sequential tests pass regardless of whether the lock exists.

**Gap filled:** `test/perfect_paper/credits_concurrency_test.exs` now provides two tests (charge + grant) that use the real concurrent execution path as oracle. These tests are currently the only tests in the suite that would detect either double-spend or double-grant.

**Both mutations restored.** The codebase was returned to its correct state after each mutation.

---

### Oracle 5: Time dimension — token expiry

**Existing test at `accounts_test.exs:412`:** Sets `inserted_at` to `~N[2020-01-01 00:00:00]` via `Repo.update_all`, then calls `get_user_by_magic_link_token/1`. Oracle is the real DB query with the `ago(^@magic_link_validity_in_minutes, "minute")` WHERE clause.

**Result: ALREADY LIT.** Tests confirm the 15-minute expiry is enforced at DB level (not just in application logic). Session token 14-day expiry similarly covered at line 389.

---

### Oracle 6: Failure dimension — post-commit event emission

**Finding from code path analysis:** `maybe_emit_low_balance/2` is called AFTER `Repo.transaction()` commits. If it raises, the credit is deducted but the caller gets an exception instead of `{:ok, event}`. This would cause the `ReviewWorker` to see `{:error, reason}` and retry, but the retry would find balance=0 and cancel with `:no_credits`.

**Assessment:** For the `credits.low` event specifically, `organization_id: nil` causes `Webhooks.dispatch/1` to short-circuit at line 42 (`def dispatch(%Event{organization_id: nil}), do: :ok`). `PubSub.broadcast/3` returns `{:ok}` or `{:error, term()}` without raising under normal operation. The most plausible raise path (Oban insert failure) is bypassed entirely for this event type.

**Residual risk:** `Events.emit` returns `{:error, changeset}` if validation fails — this error is currently swallowed by `_ = Events.emit(...)`. A misconfigured `events.low` event type would silently fail to notify. LOW risk, not an exploitable bug.

---

### Dark dimensions conclusions

**New finding from independent oracle pass:**

```
DD-1 · test/perfect_paper/credits_concurrency_test.exs · ASSERTION QUALITY · HIGH-RISK GAP ·
  The advisory lock in charge/3 and locked_insert — the sole protection against double-spend and
  double-grant races under Postgres READ COMMITTED — is completely untested by the existing 33
  sequential credit tests. Mutation proof: removing either lock does not cause a single test failure.
  Fixed: added concurrent stress tests in credits_concurrency_test.exs using :auto pool mode and
  real Postgres transaction scheduling. These are now the only tests that guard these invariants.
  No production code changes needed — the locks are correct; the test gap is what was fixed.
```

**Dimensions still dark:**
- Property/input testing (StreamData not installed — `mix.exs` has no `stream_data` dep)
- Full failure injection (process kill mid-transaction requires external coordination)
- Environment/deploy-target verification (config correctness audit would need live env)

These dimensions require installing additional tooling or live environment access; they were not lit in this pass.

**Updated totals:** 25 security findings (unchanged) + 1 test coverage gap identified and fixed.
