# Review Pipeline & Anchored Feedback — Design STUB (Piece 3 of 4)

- **Date started:** 2026-06-03
- **Status:** STUB — context captured, not yet a full design. Needs the open questions (§5)
  answered before writing-plans.
- **Depends on:** `2026-06-03-document-ssot-and-ingestion-design.md` (Piece 1, canonical AST +
  anchor schema). Benefits from but does not strictly require Piece 2 (Agent).
- **Decision rule:** a well-reasoned first-principles design is the null; the existing codebase
  and any alternative must be ≥95% likely to be a better long-run solution to displace it. No
  users → no transition cost; judge on long-run quality only.

## 1. Why this exists

This is **Step 2 of the review lifecycle**: take the canonical document (Piece 1) and produce
**anchored feedback** — comments that point at a stable node + intra-node range, not a fuzzy
quote. Today `Chatbot.review/2` returns comments with `original_text` quotes and an ordinal
`position`, with **no node anchoring**. This spec wires the model's output onto the canonical
AST and persists it as `History.Comment`s carrying `anchor_node_id` + `[anchor_from, anchor_to)`
(the fields Piece 1 lands).

## 2. Context carried from the brainstorm (locked / settled)

- **Keep the one-shot review.** Reuse the existing `Chatbot.review/2` + Anthropic forced-tool
  call. **No sub-agent fan-out** in this pass — it multiplies cost/latency and fails the 95% bar
  against the author's own "keep it cheap" constraint. (Revisit only with evidence later.)
- **The "repair ladder" is rejected.** The author proposed JSON → guess-and-fix → kick back to
  the endpoint to reformat. Forced tool use (`tool_choice` against `submit_review`'s
  `input_schema`) already returns structured args, not prose, and the adapter already gates on a
  changeset. The correct mechanism is **validate → single retry → fail**, not a multi-stage
  pattern-match repair.
- **Real gap to close:** the adapter's changeset validates **only `overall_feedback`**
  (`anthropic.ex:224`); per-comment fields are mapped without validation (`build_comments`).
  This pass should add **comment-level validation**.
- **Anchors are the point.** Comments must resolve to a `node_id` + range in the canonical doc.

## 3. What already exists to build on

- `Chatbot.review/2` → `{:ok, %{overall_feedback, comments: [%{category, suggestion,
  original_text, explanation, position}]}}`; `Chatbot.LLM` behaviour + `Stub` + `Anthropic`.
- `History`: `begin_session`, `record_progress`, `finish_session`, `dismiss_comment`,
  `address_comment`, `undo_comment_action`; `Session` (processing_status enum, processing_level
  `:preview|:full`, `overall_feedback`); `Comment` (gains anchor fields in Piece 1).
- `Credits`: usage ledger, charge-on-success pattern; `Session.processing_level` preview/full.
- `Oban` (queue `:webhooks`; Piece 1 adds `:documents`), `Events` bus (post-commit emit).
- Piece 1 canonical AST + `Session.document_id` link.

## 4. Likely scope (to confirm)

- **In:** how the LLM names the span (return node ids vs return quotes resolved server-side);
  the **anchor-resolution** step (quote → node + offset range); comment-level changeset
  validation; single-retry-on-invalid; persisting anchored comments to a Session; tying
  review to credits/entitlement and to the `:documents` conversion completion; the
  processing-status lifecycle (`analyzing → complete/failed`).
- **Out:** sub-agent fan-out; multi-model ensembles; human-in-the-loop review queues;
  re-review/diff workflows (maybe — see Q7).

## 5. Open questions (must answer before the full spec)

**Highest-impact first — Q1 is the crux.**

1. **How does the model address a span?** Two forks:
   (a) **Send flattened text + node markers** (e.g. inject node ids/sentinels) so the model
   returns `node_id` + char range directly; or
   (b) **Send plain text, model returns quotes** (`original_text` as today), and we **resolve
   quotes → node+range server-side** (exact, then normalized, then fuzzy match).
   Which? (Lean: (b) is simpler and keeps the prompt clean, but resolution must handle
   no-match / multi-node-spanning quotes. (a) is more precise but couples the prompt to our AST.)
2. **Resolution failure handling.** When a quote matches **nothing**, **multiple** places, or
   **spans multiple nodes** — drop it, attach as an un-anchored general note, or anchor to the
   best node without a range? Define the policy.
3. **Trigger & placement.** Does review run **automatically** as an Oban job right after
   conversion (`:converted` → enqueue review), or on an explicit user action? Same `:documents`
   queue or a new `:review` queue?
4. **Credits/entitlement.** How does charging interact (preview vs full)? Charge on success
   only (existing pattern)? What does a `:preview` review anchor differently from `:full`?
5. **Validation specifics.** What makes a comment invalid (missing category/suggestion? empty
   anchor when `original_text` present?) — and what exactly does the single retry re-request?
6. **Limits.** Max comments per review, max overall_feedback length, per-category caps?
7. **Idempotency / re-review.** Re-running review on an edited document — replace prior AI
   comments, version them, or diff? (Interacts with Piece 4 editing.)
8. **Streaming.** Stream comments into the LiveView as they resolve, or land them all at once
   on completion? (PubSub via `Events` is available.)
9. **Stub parity.** The `Stub` adapter must return anchorable fixtures so tests/demo exercise
   the resolution path without the live API.

## 6. Cross-spec dependencies

- **Piece 1** must be merged first (anchor schema + canonical doc + `Session.document_id`).
- **Piece 2 (Agent)** optionally supplies the composed prompt; if Piece 2 isn't ready, this pass
  uses the existing hardcoded system prompts unchanged.
