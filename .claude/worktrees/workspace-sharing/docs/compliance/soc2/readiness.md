# SOC 2 Readiness — System Description

**Artifact type:** Type II readiness (not an audit report)
**Audit period:** TBD
**Last updated:** 2026-06-02

---

## System description

PerfectPaper is an AI peer-reviewer for academic manuscripts. Authors upload documents, which the system processes through a configured language model adapter; the model's feedback is returned as structured comments attached to a proofreading session. Authors can act on comments (dismiss, address, or undo actions), and sessions may be shared within an organization. The product is accessed through a browser-based LiveView interface and a REST API secured by session tokens and API keys.

### Technology stack

| Layer | Technology |
|---|---|
| Application runtime | Elixir 1.18, Phoenix 1.8, Bandit HTTP server |
| Real-time interface | Phoenix LiveView |
| Database | PostgreSQL via Ecto ORM; binary_id (UUID) primary keys |
| Authentication | Local phx.gen.auth (password + session tokens); MFA scaffold (TOTP + WebAuthn adapters — not yet live; see `gaps.md`) |
| Authorization | `PerfectPaper.Authz` — single policy choke point with role-based + attribute-based rules and an append-only audit log |
| Input validation | `PerfectPaper.Security.UnicodeSanitizer` — invisible Unicode injection defense at request boundary and changeset level |
| Vendor adapters | Billing, LLM (Chatbot), and Blob Storage each sit behind a behaviour with a config-selected adapter; no vendor SDK leaks past the adapter boundary |
| Infrastructure | TBD (hosting provider, region, and deployment topology to be documented before audit window opens) |

---

## Trust boundary

### In scope

The following components are within the system boundary for this SOC 2 engagement:

- The PerfectPaper Phoenix application process and all Elixir modules it compiles
- The PostgreSQL database it writes to (schema, data, access controls)
- The authentication surface: session token issuance, password hashing, cookie management, MFA enforcement points (once MFA is live)
- The authorization surface: `PerfectPaper.Authz.permit?/4`, `scope_query/3`, role ladder, resource grants, and the `authz_decisions` audit log
- The REST API and LiveView surfaces, including request-level input sanitization
- API keys (issuance, hashing, revocation via `PerfectPaper.ApiKeys`)
- The Git + code-review + TDD development workflow (change management)

### Out of scope (vendor-managed, isolated behind adapters)

The following external services are consumed through anti-corruption-layer adapters. Vendor-specific credentials, error shapes, and API contracts do not cross the adapter boundary into application code. Their individual SOC 2 or equivalent attestations should be collected separately.

| Vendor concern | Adapter behaviour | Notes |
|---|---|---|
| Language model (LLM) | `PerfectPaper.Chatbot.LLM` | Manuscript text leaves the trust boundary here; LLM provider's data processing agreement is a separate control |
| Blob storage | `PerfectPaper.Documents.Storage` | Document files at rest on the provider; provider's encryption-at-rest controls apply |
| Payment processing | `PerfectPaper.Billing.Provider` | Card data never enters the application; PCI scope belongs entirely to the payment processor |
| Infrastructure / hosting | TBD | Hosting provider's physical and network controls (CC6.4, CC6.5) are out of scope for application-layer assessment |

---

## In-scope Trust Services Criteria

This engagement covers three Trust Services Criteria categories:

### Security — Common Criteria (CC1–CC9) [required]

The Security category is mandatory for every SOC 2 report. It covers the control environment, communications, risk assessment, monitoring, control activities, logical and physical access, system operations, change management, and risk mitigation. The full control map is in `controls.md`.

### Availability (A1)

The Availability category addresses whether the system is available for operation and use as committed. PerfectPaper provides no formal uptime SLA at this stage; the Availability criteria are included in scope to establish a baseline and identify the documentation gaps that must be closed before enterprise commitments can be made. See the A1 rows in `controls.md`.

### Confidentiality (C1)

The Confidentiality category addresses protection of information designated as confidential. Academic manuscripts are sensitive pre-publication documents; users upload them with an implicit expectation of confidentiality. The C1 criteria are in scope to document how manuscript data is handled, retained, and protected. See the C1 rows in `controls.md`.

---

## Overall posture

As of the date of this document, PerfectPaper's security posture is best described as follows.

**Strengths (Implemented, producing evidence today):**
Authorization is a genuine strength. The single policy choke point — `PerfectPaper.Authz.permit?/4` — enforces a well-defined role ladder (viewer, commenter, editor, admin, owner) with attribute-based session ownership and group-membership inheritance via PostgreSQL ltree. Every mutating authorization decision is recorded in the append-only `authz_decisions` table with subject, action, resource, decision outcome, and timestamp. This provides real, queryable audit evidence for CC6.1 and CC7.2 today. Input sanitization (`PerfectPaper.Security.UnicodeSanitizer`) addresses the prompt-injection attack surface at both the request boundary and changeset level. Change management is documented and practised: all code ships through named feature branches, TDD discipline (red-green-refactor), and merge-to-main review, with reversible Ecto migrations and a lint/test precommit gate.

**Partial controls requiring remediation:**
Authentication is partially implemented. Password-based login and session management are functional and follow secure patterns (session renewal on login, CSRF protection, signed cookies). Multi-factor authentication is scaffolded — the `Accounts.MFA` behaviour, stub TOTP and WebAuthn adapters, and `user_mfa_factors` / `mfa_recovery_codes` tables are in place — but no working enrollment or verification flow exists yet. The MFA secret stored in `user_mfa_factors.secret` is not yet encrypted at the application layer (CC6.7 gap). Recovery codes are not yet hashed at generation (CC6.1 gap). These are tracked as `TODO(mfa)` markers in the codebase.

**Documentation and process gaps:**
CC1 through CC5 (control environment, communications, risk assessment, monitoring activities, and control activities) are largely organizational and policy concerns. No formal information security policy, risk register, vendor management policy, or board-level oversight documentation exists. These are material gaps. Availability controls (A1) — uptime monitoring, backup verification, incident response plans — are not yet documented or formally tested. Confidentiality controls (C1) — data classification, retention schedules, disposal procedures — are also absent. All of these have `TBD` owners and must be addressed before the audit window can open.

In summary: the technical foundation for CC6 (logical access) and CC7 (monitoring/audit logging) is strong and ahead of typical early-stage products. The gaps are concentrated in organizational policies, MFA completeness, and the availability and confidentiality criteria. The control map in `controls.md` and the gap register in `gaps.md` provide the specific remediation targets.
