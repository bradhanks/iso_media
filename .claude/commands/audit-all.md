---
description: Run the full OWASP ASVS 5.0 audit team across a context/slice and merge all findings into one report. Usage: /audit-all documents
argument-hint: [context or path, e.g. documents]
---

Run a complete **OWASP ASVS 5.0** audit of: **$ARGUMENTS** (if empty, audit the whole web request surface).

You are the orchestrator running in the main session. Subagents are leaf-level and cannot spawn
other subagents, so dispatch each auditor below yourself via the Agent tool, **one at a time**,
each scoped to `$ARGUMENTS`. Wait for each to return its findings before starting the next so
context stays clean. Each auditor reads `.claude/audit/conventions.md` for the shared file map,
rules, and report schema.

Dispatch in this order:

1. `access-control-auditor`        — ASVS V8 (Authorization) — the priority pass
2. `authentication-auditor`        — ASVS V6
3. `session-auditor`               — ASVS V7
4. `api-auditor`                   — ASVS V4
5. `validation-logic-auditor`      — ASVS V2
6. `encoding-sanitization-auditor` — ASVS V1
7. `file-handling-auditor`         — ASVS V5
8. `frontend-auditor`              — ASVS V3
9. `cryptography-auditor`          — ASVS V11
10. `secure-comms-auditor`         — ASVS V12
11. `configuration-auditor`        — ASVS V13 (+ supply chain)
12. `data-protection-auditor`      — ASVS V14
13. `logging-error-auditor`        — ASVS V16
14. `secure-coding-auditor`        — ASVS V15
15. `token-auditor`                — ASVS V9  (skip if the app uses no self-contained tokens)
16. `oauth-oidc-auditor`           — ASVS V10 (skip if the app uses no OAuth/OIDC)

ASVS V17 (WebRTC) is Not Applicable for this stack — note it as such, do not dispatch.

Then produce a single merged report:
- **Group findings by severity** (HIGH → MED → LOW), then by ASVS chapter within each.
- Keep every finding's `path:line · v5.0.0-X.Y.Z · severity · chapter · issue · recommended fix` line.
- **De-duplicate** where two auditors flagged the same line — keep the higher severity and note both ASVS chapters (e.g. an owner-FK `cast` flagged by both V2 and V8).
- Add a **coverage table**: each ASVS chapter V1–V17 → audited / Not Applicable (one-line reason).
- End with a **total count by severity** and the top 5 things to fix first.

This is a report. Do not apply fixes. If the user wants remediation, that's a separate pass with
an explicitly fix-enabled agent.
