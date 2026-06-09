# SOC 2 Control-to-Code Matrix

**Artifact type:** Type II readiness (not an audit report)
**Audit period:** TBD
**Last updated:** 2026-06-02

Status legend: **Implemented** | **Partial** | **Process** | **Gap**

---

## CC1 — Control Environment

The Control Environment criteria address the tone at the top, board oversight, organizational structure, human resources policies, and the commitment to integrity and ethical values. These are primarily organizational and governance controls rather than technical ones.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC1.1 | COSO principle 1: commitment to integrity and ethical values | No formal information security or code-of-conduct policy exists. The architecture laws in `CLAUDE.md` (functional core, single authorization choke point, no bypassing context APIs) encode a technical analog of integrity at the code level, but an organizational policy is absent. | Gap | Owner TBD — draft information security policy required before audit window |
| CC1.2 | Board oversight of internal control system | No board-level oversight structure is documented. | Gap | Owner TBD |
| CC1.3 | Organizational structure and reporting lines | Not documented. | Gap | Owner TBD |
| CC1.4 | HR commitment to competence | No formal competence or training requirements documented. The TDD + code-review workflow in `CLAUDE.md` is a partial analog. | Gap | Owner TBD |
| CC1.5 | Accountability for internal control | Not documented. | Gap | Owner TBD |

---

## CC2 — Communication and Information

The Communication criteria address the organization's use of relevant information and its internal and external communication about internal controls.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC2.1 | Relevant information is identified and used to support the functioning of controls | `authz_decisions` audit log provides structured information about authorization events. No formal information-reporting or dashboard mechanism exists beyond the raw table. | Partial | Gap: no monitoring dashboard or alerting; see CC7.3 |
| CC2.2 | Internal communication of control responsibilities | No documented internal security communications program. | Gap | Owner TBD |
| CC2.3 | External communication with users and third parties | No published terms of service, privacy policy, or sub-processor list. | Gap | Owner TBD |

---

## CC3 — Risk Assessment

The Risk Assessment criteria address the identification and analysis of risks to achieving objectives.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC3.1 | Specifies objectives clearly to enable risk identification | Product specifications exist in `docs/superpowers/specs/` but no formal risk register or threat model document is maintained. | Gap | Owner TBD — formal threat model required |
| CC3.2 | Identifies and analyzes risks | No formal risk assessment process. Spec 6 design (`docs/superpowers/specs/2026-06-02-security-mfa-soc2-design.md`) identifies prompt-injection and unauthorized-access risks informally. | Gap | Owner TBD |
| CC3.3 | Considers potential for fraud in risk assessment | Not formally addressed. The `UnicodeSanitizer` addresses prompt-injection as a functional integrity concern. | Gap | Owner TBD |
| CC3.4 | Identifies and assesses changes that could significantly impact internal controls | No formal change-risk assessment process. Feature branch + TDD workflow (CLAUDE.md) provides a lightweight change gate. | Partial | Process only; formal assessment TBD |

---

## CC4 — Monitoring Activities

The Monitoring criteria address ongoing evaluation and communication of internal control deficiencies.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC4.1 | Selects, develops, and performs ongoing or separate evaluations | No automated security monitoring or periodic control evaluation process. The full ExUnit suite (`mix precommit`) runs on every merge but covers functional correctness, not control effectiveness. | Gap | Owner TBD — formal control evaluation schedule required |
| CC4.2 | Evaluates and communicates internal control deficiencies | No documented deficiency-tracking process. This gaps register is the closest artifact. | Partial | Living `gaps.md` tracks deficiencies; escalation process TBD |

---

## CC5 — Control Activities

The Control Activities criteria address policies and procedures that support the achievement of objectives and address identified risks. The architecture laws in `CLAUDE.md` provide a strong technical analog at the code level.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC5.1 | Selects and develops control activities over technology | Architecture laws in `CLAUDE.md`: single `Authz` choke point (law 1), context-only `Repo`/IO boundary (law 1), changesets on every write (law 4), typespecs always (law 5), side-effects behind behaviours (law 7). These are enforced by convention and code review; no automated linting of architectural constraints exists yet. | Process | Informal enforcement via code review; no automated architecture tests |
| CC5.2 | Selects and develops general controls over technology | Session fixation mitigation in `PerfectPaperWeb.UserAuth` (`renew_session/2` calls `configure_session(renew: true)` and `clear_session/0` on login). CSRF handled by Phoenix defaults. Input sanitization at plug layer via `PerfectPaperWeb.Plugs.UnicodeSanitizer`. | Partial | Admin email allowlist in `user_auth.ex` is config-driven but not RBAC; full admin RBAC is a future concern |
| CC5.3 | Deploys control activities through policies and procedures | Reversible Ecto migrations (`priv/repo/migrations/`). TDD discipline (red-green-refactor). Feature-branch + merge-to-main workflow. All documented in `CLAUDE.md`. | Process | Process is documented; enforcement is by convention, not automated gate |

---

## CC6 — Logical and Physical Access

This is the most technically substantive category for PerfectPaper. Spec 1 delivered real, demonstrable controls for CC6.1, CC6.8, and part of CC6.7.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC6.1 — authorization | Logical access controls restrict access based on need-to-know and least privilege | `PerfectPaper.Authz.permit?/4` is the single policy choke point; no code path may skip it. Role ladder in `PerfectPaper.Authz.Role`: `:viewer < :commenter < :editor < :admin < :owner`. `PerfectPaper.Authz.ResourceGrant` — per-resource grants attaching a role to a user or group. `PerfectPaper.Authz.scope_query/3` — narrows list queries to what the subject may read (direct ownership, group inheritance via ltree, or explicit grant). | **Implemented** (Spec 1) | — |
| CC6.1 — authentication | Logical access controls require identification and authentication | `PerfectPaperWeb.UserAuth`: `fetch_current_scope_for_user/2` (session token), `require_authenticated_user/2` (plug), `on_mount` callbacks (LiveView). Password authentication via `phx.gen.auth`. Session token reissue after 7 days; cookie max age 14 days. MFA scaffold: `PerfectPaper.Accounts.MFA` behaviour, `PerfectPaper.Accounts.MFA.TOTP` (stub), `PerfectPaper.Accounts.MFA.WebAuthn` (stub), `user_mfa_factors` table. | **Partial** | `TODO(mfa)`: enrollment/verification flow not yet wired; `user_auth.ex` login does not yet gate on MFA completion |
| CC6.1 — recovery codes | MFA recovery codes must be stored as hashes, never plaintext | `PerfectPaper.Accounts.MFA.RecoveryCode`: schema stores `code_hash` field; changeset validates presence. Hash generation at enrollment is not yet implemented. | **Partial** | `TODO(mfa)` in `RecoveryCode` module doc: "hashing on generation (SOC 2 CC6.1)" |
| CC6.1 — federated authentication | Enterprise users authenticate against their own identity provider; access is provisioned just-in-time under verified control of the email domain | `PerfectPaper.SSO`: per-org `org_sso_configs` (OIDC via Assent or real SAML via `esaml`, selectable per org). Login routes by verified email domain (`config_for_email/1`); identity resolves through the same `Accounts.resolve_sso_identity/2` guard as social login (verified-email/trusted-domain link rule, nOAuth/squatter defenses). JIT provisions org membership only when `domain_verified AND enabled`. SAML assertions are signature-validated against the org's pinned IdP cert (`SSO.SAML`), with XXE-safe parsing, XSW defense, and `InResponseTo` replay protection. Config management is org-admin gated; IdP secrets never returned by the API (`*_set` flags only). | **Implemented** (Spec 3a) | `TODO(sso)`: DNS-TXT domain-verification automation (gate enforced, lookup manual); credential encryption-at-rest (see CC6.7). SCIM deprovisioning → Spec 3b |
| CC6.2 — deprovisioning | Registration and timely deprovisioning of user access | `PerfectPaper.Scim` consumes the customer's IdP (Entra) via SCIM 2.0: `provision_user/2` (JIT membership + `scim:` identity, domain-gated) and `deactivate_user/2` (org-scoped soft-deactivate — membership `:deactivated`, group memberships stripped, `Authz.revoke_user_grants_in_org/2` removes per-resource grants; the global `users.deactivated_at` + token revocation apply only when no other org retains the user). `member.provisioned`/`member.deactivated`/`member.reactivated` events + `deactivated_at`/membership-`status` timestamps are the audit evidence. Soft-delete retains authored content for the trail. Owner-deactivation is blocked (`400 mutability`) so an IdP cannot orphan an org. The SCIM token is org-admin generated, SHA-256-hashed at rest, and authorizes only `/scim/v2`. | **Implemented** (Spec 3b) | Manual registration (non-SCIM orgs) still via `Accounts`; periodic access-review process → future |
| CC6.3 | Role-based access and least privilege | `PerfectPaper.Authz.Role` defines the minimum role required per action (e.g., `:viewer` for `:read`, `:admin` for `:delete`). `resource_grants` table records the granting user via `granted_by`. | **Partial** | No periodic access review process; role assignment audit trail covers grants but not the reviewer-approval step |
| CC6.4 | Physical access to infrastructure | Out of scope for the application layer; controlled by the hosting provider. | Gap | Hosting provider attestation TBD |
| CC6.5 | Logical access to infrastructure and network | Out of scope for application layer; controlled by hosting provider. Application-level: no direct database credentials in application code; connections via Ecto `Repo`. | Gap | Hosting provider network controls TBD; DB credential rotation policy TBD |
| CC6.6 | Logical access and transmission security (TLS) | Phoenix/Bandit serves HTTPS in production (TLS termination at the endpoint). Exact TLS version and certificate management depends on hosting configuration. | **Partial** | TLS configuration not yet formally documented; hosting/cert rotation policy TBD |
| CC6.7 | Encryption of data at rest | MFA secret material (`user_mfa_factors.secret`, type `:binary`) is stored in the database but application-layer encryption is not yet implemented. The column exists and the schema is correct; encryption is deferred. Recovery codes: `code_hash` field exists; hash function not yet applied at write time. SSO IdP credentials (`org_sso_configs.oidc_client_secret`, `org_sso_configs.saml_idp_cert`) are stored plaintext at rest pending the same app-level encryption work. SCIM bearer tokens (`scim_tokens.token_hash`) are a verify-only credential and are stored as a SHA-256 hash (never plaintext) — compliant, not pending. | **Partial** | `TODO(mfa)` in `Factor` changeset doc and `TODO(sso)` on the `oidc_client_secret`/`saml_idp_cert` fields: "app-level encryption (SOC 2 CC6.7)"; encryption-at-rest for all other PII fields (email, etc.) depends on DB-level encryption or hosting provider controls (TBD) |
| CC6.8 — input integrity | Restricts unauthorized input through boundary controls | `PerfectPaper.Security.UnicodeSanitizer`: detects and strips zero-width binary encoding (U+200B/U+200C) and Unicode Tags block (U+E0000–U+E007F) used for LLM prompt injection. Applied at both request boundary (`PerfectPaperWeb.Plugs.UnicodeSanitizer`) and changeset level (`validate_no_hidden_unicode/2`). | **Implemented** (Spec 6) | — |

---

## CC7 — System Operations

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC7.1 | Infrastructure and software management | Reversible Ecto migrations with timestamps. Dependency management via `mix.lock`. No automated vulnerability scanning. | **Partial** | No CVE scanning on dependencies; no infrastructure-as-code audit trail |
| CC7.2 — audit logging | Detects and monitors for unauthorized access and anomalies | `PerfectPaper.Authz.Decision` + `authz_decisions` table (append-only, no `updated_at`): records `subject_id`, `action`, `resource_type`, `resource_id`, `decision` (ok / unauthorized / not_found), `reason`, and `inserted_at` for every mutating authorization decision (`:edit`, `:delete`, `:share`, `:manage_members`). Indexed on `subject_id` and `(resource_type, resource_id)` for efficient queries. Outbound webhook deliveries are logged in `webhook_deliveries` (`PerfectPaper.Webhooks.Delivery` schema / `Webhooks.Delivery.Worker`): records delivery status, attempt count, and HTTP response per dispatch — queryable evidence of system-activity notification attempts. | **Implemented** (Spec 1, mutating actions; Spec 8, webhook delivery log) | Read actions (`:read`, `:comment`) are not logged — `TODO` in `Decision` module doc; see `gaps.md` |
| CC7.3 — anomaly detection | Evaluates security events to identify anomalies and threat indicators | No anomaly detection, alerting, or SIEM integration exists. | Gap | Future specification TBD; see `gaps.md` |
| CC7.4 — incident response | Responds to security incidents | No documented incident response plan. | Gap | Owner TBD |
| CC7.5 — recovery | Restores operations after security incidents | No documented recovery procedures. | Gap | Owner TBD |

---

## CC8 — Change Management

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC8.1 | Controls over infrastructure and software changes | Feature-branch Git workflow: every change ships on a uniquely named branch cut from `main`, with red-green-refactor TDD, a passing `mix precommit` gate (compile with warnings-as-errors, unused deps check, format, full test suite), and a merge back to `main`. Documented in `CLAUDE.md`. Ecto migrations are reversible (use `change/0` or explicit `up/down`). Migration history is append-only in `priv/repo/migrations/`. | **Process** | Process is documented and practised; no automated enforcement of branch-protection rules (GitHub/hosting platform configuration TBD) |

---

## CC9 — Risk Mitigation

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| CC9.1 | Identifies, selects, and develops risk mitigation for business disruption | No formal business continuity plan or risk mitigation inventory. | Gap | Owner TBD |
| CC9.2 — vendor management | Manages vendor risks through assessments and contracts | Third-party vendors (LLM, storage, payments) are isolated behind adapter behaviours: `PerfectPaper.Chatbot.LLM`, `PerfectPaper.Documents.Storage`, `PerfectPaper.Billing.Provider`. No vendor credential or API shape leaks past the adapter. Formal vendor risk assessments, DPAs, and sub-processor agreements are not yet documented. | **Partial** | Vendor DPAs and risk assessments TBD; sub-processor list TBD |

---

## A1 — Availability

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| A1.1 | Current processing capacity and performance commitments | No uptime SLA. No performance baselines documented. | Gap | Hosting provider + monitoring setup TBD |
| A1.2 | Environmental, regulatory, and technological changes are monitored | No formal monitoring of environmental or regulatory changes. | Gap | Owner TBD |
| A1.3 — backups | Data backups and recovery procedures | Database backup strategy depends on hosting provider configuration. No documented backup frequency, retention period, or tested recovery procedure. | Gap | Hosting provider backup policy TBD; recovery test schedule TBD |

---

## C1 — Confidentiality

Academic manuscripts uploaded to PerfectPaper are sensitive pre-publication documents. The C1 criteria are material for this product.

| Control ID | Description (abridged) | Implementation / code location | Status | Gap / TODO |
|---|---|---|---|---|
| C1.1 — data classification | Identifies and classifies confidential information | No formal data classification policy. Manuscripts are stored as blobs via the `Documents.Storage` adapter; the adapter boundary prevents raw file access from the application, but no classification label, handling requirement, or retention schedule is defined. | Gap | Data classification policy TBD; owner TBD |
| C1.2 — data disposal | Disposes of confidential information according to policy | No documented retention or disposal policy. Account deletion cascades via database constraints; no formal document purge schedule exists. | Gap | Retention and disposal policy TBD; owner TBD |
