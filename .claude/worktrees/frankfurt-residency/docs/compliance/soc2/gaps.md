# SOC 2 Readiness — Open Gaps Register

**Artifact type:** Type II readiness (not an audit report)
**Audit period:** TBD
**Last updated:** 2026-06-02

This register is the consolidated list of known control gaps. Each entry identifies
the criterion it blocks, the remediation path (a `TODO()` tag in the codebase, a
future specification number, or a policy owner), and a brief note on urgency.

All gaps must be closed — or compensated with a documented and auditor-accepted
compensating control — before the Type II audit window opens.

---

## Format

| Field | Description |
|---|---|
| Gap | What is missing |
| Criterion | The Trust Services Criterion this gap blocks or weakens |
| Status | Gap or Partial (Partial = some code exists; Gap = nothing) |
| Remediation path | `TODO()` tag in code, future Spec, or policy owner TBD |
| Notes | Any compensating control in place today |

---

## Authentication and MFA gaps

### GAP-001 — MFA enrollment and verification flow not implemented

| Field | Value |
|---|---|
| Gap | No working MFA enrollment or verification UI or ceremony exists. Users cannot enroll a TOTP authenticator or a WebAuthn/passkey factor. The login flow does not gate on MFA completion even for users with `mfa_enabled: true` or organizations with `mfa_required: true`. |
| Criterion | CC6.1 (logical access — authentication) |
| Status | Partial (scaffold in place; flow not wired) |
| Remediation path | `TODO(mfa)` markers in `lib/perfect_paper/accounts/mfa/totp.ex`, `lib/perfect_paper/accounts/mfa/web_authn.ex`, and enforcement-point markers in `lib/perfect_paper_web/user_auth.ex`; full implementation is the MFA build-out pass following Spec 6 |
| Notes | Password authentication is functional. MFA is a strong authentication requirement for CC6.1 at the enterprise tier; its absence is a known, tracked gap. |

### GAP-002 — MFA secret not encrypted at rest

| Field | Value |
|---|---|
| Gap | The `user_mfa_factors.secret` column (type `:binary`) stores adapter-owned MFA material (TOTP secret or WebAuthn credential id + public key) in the database without application-layer encryption. Database-level encryption depends on the hosting provider and is not yet documented. |
| Criterion | CC6.7 (encryption of data at rest) |
| Status | Partial (column exists; application-layer encryption not implemented) |
| Remediation path | `TODO(mfa)` in `PerfectPaper.Accounts.MFA.Factor` changeset doc: "app-level encryption (SOC 2 CC6.7)" — implement with an application-level field encryption library before the MFA build-out pass |
| Notes | No MFA secrets are stored today (adapters are stubs). The gap becomes material when the MFA enrollment flow is implemented. |

### GAP-003 — MFA recovery codes not hashed at generation

| Field | Value |
|---|---|
| Gap | The `mfa_recovery_codes.code_hash` column and the `RecoveryCode` changeset are in place, but the hash function is not applied when recovery codes are generated. Plaintext codes could be written if the enrollment flow were wired prematurely. |
| Criterion | CC6.1 (logical access — authentication / credential storage) |
| Status | Partial (schema correct; write path not implemented) |
| Remediation path | `TODO(mfa)` in `PerfectPaper.Accounts.MFA.RecoveryCode` module doc: "hashing on generation (SOC 2 CC6.1)" — apply a cryptographic hash (e.g., `Bcrypt` or `Argon2`) before persisting `code_hash` |
| Notes | No recovery codes are written today. The gap becomes material at the MFA build-out pass. |

### GAP-004 — MFA enforcement not wired at login, API token issuance, or LiveView mount

| Field | Value |
|---|---|
| Gap | Three enforcement choke points are identified in the design but carry only `TODO(mfa)` stubs: (1) browser login (`user_auth.ex` — MFA challenge step before session establishment), (2) API token issuance (bearer token must not be minted for an MFA-required user without verified factor), (3) LiveView `on_mount :require_mfa` hook. |
| Criterion | CC6.1 (logical access — authentication) |
| Status | Gap (code markers exist; logic not implemented) |
| Remediation path | `TODO(mfa)` markers at the real call sites in `lib/perfect_paper_web/user_auth.ex` (login + on_mount) and the API token path; implemented as part of the MFA build-out pass |
| Notes | — |

---

## Audit logging gaps

### GAP-005 — Read actions not logged in `authz_decisions`

| Field | Value |
|---|---|
| Gap | `PerfectPaper.Authz.maybe_log/5` only writes a decision row for mutating actions (`:edit`, `:delete`, `:share`, `:manage_members`) as determined by `PerfectPaper.Authz.Role.mutating?/1`. Read actions (`:read`, `:comment`) are not logged. An auditor seeking to verify that no unauthorized reads occurred cannot reconstruct a read access trail from `authz_decisions` alone. |
| Criterion | CC7.2 (audit logging / monitoring of unauthorized access) |
| Status | Partial (mutating actions logged; reads are not) |
| Remediation path | Noted explicitly in `PerfectPaper.Authz.Decision` module doc: "Reads are not logged in Spec 1." A follow-on pass should add read-action logging, potentially with a sampling or threshold policy to manage volume. |
| Notes | Mutating action logging is fully implemented and constitutes real CC7.2 evidence today. Read-action logging is an enhancement, not a blocker for the initial audit period if compensating controls are accepted. |

---

## Anomaly detection and incident response gaps

### GAP-006 — No anomaly detection or alerting

| Field | Value |
|---|---|
| Gap | No mechanism exists to detect anomalous authorization patterns (e.g., a spike in unauthorized decisions for one subject, repeated failed authentication, mass resource access). No SIEM integration, no alerting rules, and no on-call process. |
| Criterion | CC7.3 (evaluates security events to identify anomalies and threat indicators) |
| Status | Gap |
| Remediation path | Future specification TBD; requires a monitoring/observability pass (candidate: integrate structured logging from `authz_decisions` into a SIEM or alerting stack) |
| Notes | The `authz_decisions` table provides the raw data; the analysis layer is absent. |

### GAP-007 — No documented incident response plan

| Field | Value |
|---|---|
| Gap | No documented procedure for detecting, containing, investigating, or notifying affected parties of a security incident. |
| Criterion | CC7.4 (incident response), CC2.3 (external communications) |
| Status | Gap |
| Remediation path | Policy owner TBD — an incident response playbook is required before the audit window opens |
| Notes | — |

### GAP-008 — No documented recovery procedures

| Field | Value |
|---|---|
| Gap | No documented procedure for restoring the system to operation after a security incident or outage. |
| Criterion | CC7.5 (recovery from security incidents), A1.3 (backup and recovery) |
| Status | Gap |
| Remediation path | Policy owner TBD — recovery procedures are part of a business continuity plan |
| Notes | — |

---

## Access provisioning and deprovisioning gaps

### GAP-009 — No SCIM deprovisioning

| Field | Value |
|---|---|
| Gap | When a user is removed from an organization in an upstream identity provider (e.g., Entra ID / Azure AD), no automated signal reaches PerfectPaper to revoke that user's group memberships, resource grants, and session tokens. |
| Criterion | CC6.2 (registration and deprovisioning of user access) |
| Status | Gap |
| Remediation path | Spec 3 (Entra SSO / SCIM) — SCIM provisioner will deliver deprovisioning events; resource grants and group memberships to be cleared on SCIM DELETE |
| Notes | Manual deprovisioning is possible through the `Accounts` context today; the gap is the automated/timely signal from the IdP. |

### GAP-010 — No periodic access review

| Field | Value |
|---|---|
| Gap | No scheduled process reviews outstanding resource grants or group memberships to confirm they are still appropriate. The `resource_grants` table records `granted_by` but there is no review workflow. |
| Criterion | CC6.3 (role-based access and least privilege) |
| Status | Gap |
| Remediation path | Process owner TBD — a periodic (e.g., quarterly) access review process is required |
| Notes | — |

---

## Organizational and policy gaps

### GAP-011 — No formal CC1–CC5 organizational policies

| Field | Value |
|---|---|
| Gap | The following policies do not exist as formal documents: information security policy (CC1.1), board oversight structure (CC1.2), organizational reporting lines (CC1.3), human resources competence requirements (CC1.4/CC1.5), internal security communications program (CC2.2), external communications / privacy policy (CC2.3), formal risk register (CC3.1/CC3.2), threat model (CC3.2), formal change-risk assessment (CC3.4), and a formal control evaluation schedule (CC4.1). |
| Criterion | CC1.1 through CC5.3 (control environment, communications, risk assessment, monitoring activities, control activities) |
| Status | Gap |
| Remediation path | Policy owner TBD — all organizational policies must be drafted, approved by appropriate leadership, and maintained before the audit window opens |
| Notes | The architecture laws in `CLAUDE.md` provide a strong technical analog for CC5 (control activities in code), but they are enforced by convention rather than a formal policy framework. |

### GAP-012 — No formal vendor DPAs or sub-processor list

| Field | Value |
|---|---|
| Gap | Data processing agreements with the LLM provider, blob storage provider, and payment processor have not been collected or documented. No published sub-processor list exists for users. |
| Criterion | CC9.2 (vendor risk management), C1.1 (data classification and handling) |
| Status | Gap |
| Remediation path | Policy owner TBD — DPAs and sub-processor documentation required before audit window opens or before GDPR/enterprise data processing agreements are made |
| Notes | The adapter-boundary pattern in the codebase (`Chatbot.LLM`, `Documents.Storage`, `Billing.Provider`) limits what data reaches each vendor; the contractual layer is absent. |

---

## Availability gaps

### GAP-013 — No uptime monitoring, SLA, or capacity baselines

| Field | Value |
|---|---|
| Gap | No uptime SLA is published or committed to. No performance baselines or capacity monitoring are in place. |
| Criterion | A1.1 (current processing capacity and performance commitments) |
| Status | Gap |
| Remediation path | Hosting provider + monitoring setup TBD |
| Notes | — |

### GAP-014 — No documented backup and recovery verification

| Field | Value |
|---|---|
| Gap | Database backup strategy depends on hosting provider configuration. No documented backup frequency, retention period, or tested recovery procedure exists. |
| Criterion | A1.3 (backups and recovery) |
| Status | Gap |
| Remediation path | Hosting provider backup policy TBD; recovery test schedule TBD |
| Notes | — |

---

## Confidentiality gaps

### GAP-015 — No data classification policy

| Field | Value |
|---|---|
| Gap | No formal data classification policy exists. Academic manuscripts are sensitive pre-publication documents, but no classification label, handling requirement, or retention schedule has been defined. |
| Criterion | C1.1 (identification and classification of confidential information) |
| Status | Gap |
| Remediation path | Policy owner TBD — data classification policy must cover at minimum: manuscript content, user PII (email, password hash), MFA secrets, API keys, and payment references |
| Notes | The `Documents.Storage` adapter boundary limits raw file access from the application layer, but the classification and handling policies that govern the data behind that boundary are absent. |

### GAP-016 — No data retention and disposal policy

| Field | Value |
|---|---|
| Gap | No documented retention schedule or disposal procedure for manuscripts, session history, user accounts, or audit logs. Account deletion cascades via database constraints, but no formal document purge schedule or verified disposal workflow exists. |
| Criterion | C1.2 (disposal of confidential information) |
| Status | Gap |
| Remediation path | Policy owner TBD — retention policy required before enterprise data processing agreements |
| Notes | — |

---

## Infrastructure and TLS gaps

### GAP-017 — TLS configuration not formally documented

| Field | Value |
|---|---|
| Gap | Phoenix/Bandit serves HTTPS in production, but the specific TLS version, cipher suites, certificate authority, and certificate rotation policy have not been formally documented. |
| Criterion | CC6.6 (transmission security) |
| Status | Partial |
| Remediation path | Hosting/infrastructure documentation TBD — document TLS version floor (minimum TLS 1.2, preferably TLS 1.3), certificate management, and rotation schedule |
| Notes | — |

### GAP-018 — Hosting provider physical and network controls not attested

| Field | Value |
|---|---|
| Gap | CC6.4 (physical access to infrastructure) and CC6.5 (logical access to infrastructure and network) are out of scope for the application layer but require the hosting provider's SOC 2 attestation or equivalent. That attestation has not been collected. |
| Criterion | CC6.4, CC6.5 |
| Status | Gap |
| Remediation path | Collect hosting provider SOC 2 Type II report (or equivalent); document in the vendor management records |
| Notes | — |

---

## Dependency and vulnerability scanning gap

### GAP-019 — No CVE scanning on Elixir dependencies

| Field | Value |
|---|---|
| Gap | No automated dependency vulnerability scanning runs in CI or on a schedule. `mix.lock` pins dependency versions but there is no check against a CVE database. |
| Criterion | CC7.1 (infrastructure and software management) |
| Status | Gap |
| Remediation path | Add `mix hex.audit` or integrate with a CVE scanning service in CI; schedule periodic dependency review |
| Notes | `mix deps.unlock --unused` runs as part of `mix precommit`, ensuring unused dependencies are not carried, but this does not detect vulnerabilities in used dependencies. |

---

## Summary counts

| Status | Count |
|---|---|
| Gap | 14 |
| Partial | 5 |
| **Total open items** | **19** |

Gaps are prioritized roughly in the order a SOC 2 auditor would surface them:
authentication completeness (GAP-001 through GAP-004) and audit logging completeness
(GAP-005) are the highest-urgency technical gaps because they affect active controls.
Organizational policies (GAP-011) and vendor DPAs (GAP-012) require the most lead
time to draft, approve, and evidence. Availability and confidentiality gaps (GAP-013
through GAP-016) are real but unlikely to block a first Type II opinion if a clear
remediation plan and timeline are provided to the auditor.
