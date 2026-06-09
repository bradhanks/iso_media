# docx Upload Wiring — Design (Piece A)

- **Date:** 2026-06-04
- **Status:** Draft for review
- **Depends on:** Step 1 (Document SSoT & Ingestion — shipped to `main`): `Documents.ingest/3`,
  `Documents.Conversion` (Oban), `Documents.Importer.Pandoc`, `Documents.Canonical`,
  `DocumentComponents.render_tree/1`, `Session.document_id`, the `document.converted` /
  `document.conversion_failed` events.
- **Decision rule:** a well-reasoned first-principles design is the null; deviations must clear
  ≥95% to displace it.

## 1. Problem
The shipped ingestion engine works and is tested, but **nothing calls it**. `/new` (NewLive) still
uses the *old* path — `store_and_register` + synchronous `process_session` on **raw file bytes** —
so an uploaded manuscript never produces a `canonical_doc`, never renders in the workspace, and the
review receives binary garbage for non-text files. This piece connects the upload to the canonical
pipeline. **docx-only** (PDF parked — see `backlog/2026-06-04-pdf-ingestion-design.md`).

## 2. Locked decisions (from brainstorm)
- **Async conversion flow.** Upload → `ingest/3` → redirect to the workspace in a "Converting…"
  state → the `document.converted` event live-updates the manuscript pane when the canonical body
  is ready. (Chosen over synchronous/​hybrid; matches the Oban/Events architecture and survives
  future slow extractors.)
- **Chained review.** After conversion, the existing `History.process_session` review runs **async**
  on the **canonical text** (`Canonical.flatten_text(canonical_doc)`), not raw bytes. Comments
  appear when ready. Deeper *anchored*-comment work stays in the deferred review-pipeline spec;
  comments remain un-anchored here (same as today), but the manuscript body finally renders.
- **docx-only.** `/new` accepts `.docx` only.

## 3. Scope

### In
1. **NewLive (`/new`)**
   - `@accept` → `~w(.docx)`; update copy + `error_text(:not_accepted)` to say "Upload a .docx file."
   - Rewrite `submit`: synchronous **best-effort credit pre-check** (fast-fail with the existing
     "out of credits" message so the user learns immediately — and so we don't spend LLM tokens for
     a user already at zero) → `Documents.ingest(user, content, %{filename:, content_type:,
     source_format: "docx"})` → `History.begin_session(%{user_id:, title:, document_id: document.id})`
     → `push_navigate` to `~p"/workspace/#{session.id}"`.
   - **Default the title** to the filename minus extension (`Path.rootname(entry.client_name)`) so the
     workspace is immediately recognizable.
   - **`phx-disable-with`** on the submit button — defense-in-depth against double-submit (the ledger
     is already race-safe; see §6 #2).
   - Drop the `store_and_register` + synchronous `process_session` calls **from NewLive** (the
     functions stay; only NewLive's usage changes).
2. **WorkspaceLive** — render conversion state:
   - `mount`: when `connected?`, subscribe to the **document-scoped** topic `"document:#{document_id}"`
     — NOT the global `events:document.converted` type-topic, which would fan every user's conversion
     out to every open workspace (an O(N²) re-fetch storm). Assign `canonical_doc` (nil until
     converted) + a `conversion_status` derived from the document.
   - Three states in the manuscript pane: **converting** (doc pending/converting → "Converting your
     manuscript…"), **ready** (`canonical_doc` present → `render_tree`), **failed**
     (`document.conversion_failed` / status `:failed` → "We couldn't process that file").
   - Handle the scoped `{:document_converted, id}` / `{:document_conversion_failed, id}` messages →
     re-fetch document + session, re-assign. (Comments render via the existing feedback pane when the
     chained review completes.)
3. **Chained review trigger** — on successful conversion, run the review for the linked session,
   async, on canonical text. **Decision (§6 #1):** the `Conversion` worker, on `:converted`,
   (a) broadcasts terminal status to the scoped `"document:#{id}"` topic for the live UI, and
   (b) enqueues a thin review job for the session(s) linked to the document, via a new
   `History.sessions_for_document/1` query; the review job calls `History.process_session(session,
   Canonical.flatten_text(canonical_doc))`.
   The review job is **idempotent**: Oban `unique` keyed on `session_id` (states
   `available/scheduled/executing/retryable`), so a `Conversion` retry (network drop, lock timeout,
   worker restart) cannot enqueue a duplicate review — duplicates mean duplicate **paid LLM calls**.

### Out
PDF and any non-docx format · OCR · anchored comments (review-pipeline spec) · redesigning
`process_session` / the review itself · changing the static `/demo/review` walkthrough.

## 4. Data flow
```
/new submit ─ credit pre-check ─► Documents.ingest(docx)         (Document :pending, enqueue Conversion)
            └─► History.begin_session(document_id) ─► redirect ─► /workspace/:id  ("Converting…")
Conversion worker ─► canonical_doc ─► emit :document.converted ──► WorkspaceLive live-updates (renders body)
                                   └─► enqueue review (session) ─► process_session(flatten_text) ─► comments
```

## 5. Error handling
- **No credits** → caught synchronously at submit; immediate inline message; nothing ingested.
- **Conversion failure** (corrupt/non-docx-masquerading) → deterministic → document `:failed` +
  `:document_conversion_failed` → workspace "failed" state.
- **Review failure** (e.g., `:no_credits` race, LLM error) → existing `process_session` handling;
  surface a non-blocking notice in the workspace; the rendered manuscript still stands.

## 6. Decisions to confirm
1. **Review chaining mechanism.** Recommended: `Conversion` worker enqueues the review via
   `History.sessions_for_document/1`. Alternatives considered: an Events subscriber GenServer, or
   WorkspaceLive triggering it (rejected — risks multi-viewer double-fire). Worker-chain is
   explicit and testable.
2. **Credits — keep charge-post-success; do NOT add reserve/refund.** Verified against the code:
   `Credits.charge/3` runs inside a `lock_user` row-lock, and `process_session` charges inside its
   `Ecto.Multi` *after* a successful review — so the ledger is **already serialized against
   concurrent double-spend** (a second concurrent charge sees the reduced balance → `:no_credits`).
   A reserve-at-submit + refund scheme would be a redesign that adds refund failure-modes and
   discards the clean property that we never charge for a failed conversion/LLM error — it does not
   clear the 95% bar. We keep: (a) a **best-effort synchronous pre-check** at submit (UX fast-fail +
   avoids LLM spend for users already at zero; the authoritative charge stays in `process_session`);
   (b) **idempotent review enqueue** (§3.3) + **`phx-disable-with`** — together these remove the only
   real residual of a double-submit, which is *wasted LLM tokens*, not ledger corruption. The async
   path can still hit `:no_credits` (balance changed between pre-check and the async charge) →
   surfaced as the workspace review-failure notice (§5).
3. **`process_session` input.** It currently takes raw `content`; the review job passes
   `flatten_text(canonical_doc)`. Confirm `process_session/2`'s signature accommodates a text string
   (it should — today it's fed file bytes as "text").

## 7. Testing
- **NewLive:** uploading a `.docx` calls `ingest/3` (Stub importer in test), creates a session with
  `document_id`, redirects to the workspace; a non-`.docx` is rejected by `@accept`; out-of-credits
  shows the inline message and ingests nothing.
- **Conversion → review chain:** `perform_job(Conversion, …)` on a converted doc enqueues the review
  job for the linked session (`assert_enqueued`); the review job runs `process_session` on canonical
  text and the session gains comments + completes.
- **WorkspaceLive states:** converting (no `canonical_doc`) shows the converting copy; after a
  `document.converted` event the rendered body (`node-…` markers) appears; a `conversion_failed`
  event shows the failed state.
- Hermetic via the Stub importer; any real-pandoc docx assertion tagged `:pandoc`.

## 8. Files (anticipated)
- Modify: `lib/perfect_paper_web/live/new_live.ex` (+ template), `lib/perfect_paper_web/live/workspace_live.ex`,
  `lib/perfect_paper/documents/conversion.ex` (enqueue review on success), `lib/perfect_paper/history.ex`
  (`sessions_for_document/1`).
- Create: a thin review Oban worker (e.g. `lib/perfect_paper/history/review_worker.ex`, queue
  `:reviews`, `unique: [keys: [:session_id], states: ~w(available scheduled executing retryable)a]`)
  + config queue entry.
- Tests alongside each.

## 9. Revisions
- **2026-06-04 — review 1.** Incorporated: (#1) document-scoped PubSub topic `"document:#{id}"` to
  avoid an O(N²) re-fetch storm across open workspaces (§3.2, §3.3); (#3) idempotent review enqueue
  via Oban `unique` on `session_id` — prevents duplicate paid LLM calls on `Conversion` retry (§3.3);
  (#4) default session title from filename (§3.1); plus a `phx-disable-with` double-submit guard.
  (#2) **Rejected** the reserve/refund credit redesign after verifying the ledger is already
  race-safe (`lock_user` + charge-post-success); kept the best-effort pre-check and rely on #3 +
  the button guard for the double-submit residual (§6 #2).
