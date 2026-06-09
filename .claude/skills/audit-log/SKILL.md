---
name: audit-log
description: Internal append-only findings ledger format and rules. Reference knowledge for reviewer agents; not a user command.
user-invocable: false
---

# Audit log — append-only findings ledger

After producing your verdict, record each finding to the shared ledger at **`docs/specs/_audit/audit.jsonl`** (path is relative to the repo root; it is committed, not gitignored). This is the ONE file you write — never use Write/Edit, never touch the spec or plan files.

## Rules
- **Append only, one JSON object per line (JSONL).** Never rewrite the file — multiple agents and runs share it, and a rewrite clobbers others' findings.
- Ensure the dir exists, then append one line per finding:

    mkdir -p docs/specs/_audit
    printf '%s\n' '<single-line-json>' >> docs/specs/_audit/audit.jsonl

The JSON must be a single line with no embedded newlines.
- Resolve `feature`, `phase`, `total_phases`, `multi_phase`, `spec_file`, `plan_file`, `review_pass`, `model` from the pipeline state file and the delegation prompt. If a field is unknown (e.g. running standalone), use `null`.

## Schema (every field)

| field | type | notes |
|-------|------|-------|
| `audit_version` | int | start at `1`; bump when this schema changes |
| `ts` | string | ISO 8601 UTC, e.g. `2026-06-06T14:32:00Z` |
| `agent` | string | `spec-editor` \| `plan-editor` |
| `model` | string | `opus` \| `sonnet` \| `haiku` |
| `feature` | string | from state.json |
| `phase` | int\|null | `null` for spec-level findings not tied to a phase |
| `total_phases` | int\|null | |
| `multi_phase` | bool | |
| `spec_file` | string | path |
| `plan_file` | string\|null | `null` for spec-editor findings |
| `review_pass` | int | which convergence pass (1–3) surfaced it |
| `finding_id` | string | short + unique, e.g. `f-7b2c91` |
| `type` | string | short slug, e.g. `migration_safety`, `liveview_lifecycle`, `otp_supervision`, `context_boundary`, `vendor_coupling`, `sync_correctness` |
| `rubric_ref` | int | the `elixir-otp-rubric` standard (1–10) this maps to |
| `severity` | string | `critical` \| `major` \| `minor` |
| `status` | string | `open` \| `fixed` \| `accepted` \| `wontfix` |
| `locations` | array | `[{"file":"<path>","lines":"88-104"}]` — list spec/plan AND implementation files |
| `recurring_key` | string | **stable slug for the KIND of problem** (`count-star-invoice-numbering-race`, `updated-at-sync-cursor`, `string-to-atom-leak`). This is what makes cross-feature pattern mining work. |
| `description` | string | one sentence |
| `fix` | string | one sentence |

## Example line

```json
{"audit_version":1,"ts":"2026-06-06T14:32:00Z","agent":"plan-editor","model":"opus","feature":"service_olympus","phase":7,"total_phases":11,"multi_phase":true,"spec_file":"docs/specs/service_olympus/optimized-spec.md","plan_file":"docs/specs/service_olympus/phase-7/draft-plan.md","review_pass":2,"finding_id":"f-7b2c91","type":"migration_safety","rubric_ref":4,"severity":"critical","status":"open","locations":[{"file":"docs/specs/service_olympus/phase-7/draft-plan.md","lines":"88-104"},{"file":"lib/service_olympus/billing/invoice.ex","lines":"31-39"}],"recurring_key":"count-star-invoice-numbering-race","description":"invoice number via count(*)+1 races under concurrency","fix":"atomic UPSERT+RETURNING per-org counter"}