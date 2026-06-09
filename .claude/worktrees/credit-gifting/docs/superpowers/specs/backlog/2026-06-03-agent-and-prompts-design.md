# Agent & Prompts — Design STUB (Piece 2 of 4)

- **Date started:** 2026-06-03
- **Status:** STUB — context captured, not yet a full design. Needs the open questions (§5)
  answered before writing-plans.
- **Depends on:** `2026-06-03-document-ssot-and-ingestion-design.md` (Piece 1). Does **not**
  block Piece 1.
- **Decision rule:** a well-reasoned first-principles design is the null; the existing codebase
  and any alternative must be ≥95% likely to be a better long-run solution to displace it. No
  users → no transition cost; judge on long-run quality only.

## 1. Why this exists

The author wants the reviewer's behavior to be **configurable per tenant**, not hardcoded.
Today the review/chat prompts are **constants inside the Anthropic adapter**
(`lib/perfect_paper/chatbot/llm/anthropic.ex`): `@chat_system`, `@full_review_system`,
`@preview_review_system`. There is no per-org, per-group, or per-user prompt, and no entity
representing "the agent."

The goal: an **Agent** whose behavior is composed from layered prompts —
**system (product) + org-level + owner-level** — where org/group admins (or the owning user)
can edit their layer in settings, while the product's hardening layer stays non-overridable.

## 2. Context carried from the brainstorm (locked)

- **"Agent" is not a new context.** It lives in `Chatbot`. Chatbot already exposes both
  `complete/1` (chat) and `review/2` (the agentic review) over the one `LLM` behaviour — chat
  and agent **already share context**. (Confirmed against code; the author's instinct was right.)
- **Prompts become composable layers, not one blob.** The hardcoded constants become the
  *product/system* layer; org and owner layers are appended.
- **Hardening is non-overridable.** Whatever the layering, prompt-injection / safety hardening
  must not be defeatable by an org or user prompt. (Security invariant — high confidence.)
- **Reuse existing ownership primitives.** `Organizations` already has polymorphic ownership
  (`owner_type ∈ {:user,:group}`, `owner_id`, denormalized `org_id`, `ltree` group paths) and
  `admin?/2`. The owner layer should hang off these, not a new ownership scheme.
- **Changeset on every write** (incl. prompt text validation), context is the only IO boundary,
  adapters hide vendor specifics — all architecture laws apply.

## 3. Likely scope (to confirm)

- **In:** an `Agent` representation (entity or config — see Q1); layered prompt composition
  (system + org + owner + hardening) with a defined precedence; validation + length/abuse
  limits on editable layers; resolution of "which agent applies to this document" via existing
  ownership; settings surfaces for org/group admins and individual users to edit their layer.
- **Out (probably):** multiple named personas per tenant, prompt A/B testing, per-agent model
  marketplaces, fine-tuning. RAG / knowledge bases.

## 4. What already exists to build on

- `Chatbot.review/2`, `Chatbot.complete/1`; `Chatbot.LLM` behaviour; `Anthropic` adapter
  (forced tool use, `claude-haiku-4-5`, validates result via changeset).
- `Organizations`: orgs, memberships (owner/admin/member), groups (ltree), group memberships,
  `admin_orgs/1`, `admin?/2`, MFA policy pattern (a good template for "org-scoped setting").
- `org_sso_configs` table (precedent for per-org configuration rows).

## 5. Open questions (must answer before the full spec)

**Highest-impact first.**

1. **Entity vs config.** Is an Agent a **persisted entity** (a row, editable, versioned) or
   just a **prompt-composition computed from settings** at call time? (My lean: persisted prompt
   *layers* attached to owners, composed at call time — not a heavyweight "Agent" object. Confirm.)
2. **Layer precedence & merge.** Exact order and semantics: `hardening (non-overridable) +
   system + org + group(s, down the ltree?) + user`? Do deeper group prompts append or replace
   ancestors? Can an org prompt *narrow* (forbid) something the system prompt allows?
3. **Which layers exist for which owners.** A document owned by a user inside a group inside an
   org — do we compose org + group + user prompts, or only the most specific? How do nested
   groups (ltree) contribute?
4. **Who can edit each layer.** Org layer → org owner/admin (`admin?/2`)? Group layer → group
   admin/owner? User layer → the user? Confirm the authorization matrix.
5. **Chat vs review.** Does the agent config affect **both** `complete/1` (chat) and `review/2`,
   or only review? (They have different system prompts today.)
6. **Model selection.** Is the model (`claude-haiku-4-5` vs others) part of agent config (data)
   or fixed config? Per-tier? (Ties into Credits.)
7. **Safety.** How do we harden editable prompts against injection / jailbreaks of the
   non-overridable layer? Validation rules, length caps, disallowed content, review?
8. **Versioning/audit.** Do prompt edits need history (who changed what, when) — reuse the
   `Events` bus / a deliveries-style log?
9. **Settings UI placement.** Org settings page, group settings page, user settings page — which
   exist, which are new, and what's the editing UX (plain textarea? guided fields)?
10. **Defaults & empty state.** What does a tenant with no custom prompt get (just system +
    hardening)? Can they preview the composed prompt?

## 6. Cross-spec dependencies

- Consumes Piece 1 only indirectly (the agent reviews the canonical doc; that wiring is Piece 3).
- Authorization for "who can edit" may want the deferred `Authz` context
  (`2026-06-02-enterprise-tenancy-authz-foundation-design.md`); confirm whether to route
  through it or use `Organizations.admin?/2` directly for now.
