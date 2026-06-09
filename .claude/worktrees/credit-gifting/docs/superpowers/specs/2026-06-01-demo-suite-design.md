# Demo suite — review lifecycle, account surfaces, and microinteractions

**Date:** 2026-06-01
**Status:** approved (brainstorm)

## Goal

Turn `/demo` from a single static workspace into a public, no-auth **demo suite**
that shows off PerfectPaper's groundbreaking functionality end to end, with
charming-but-editorial microinteractions. The demo is the reference the real app
matches; it reuses real components and the hero animation's existing CSS so the
motion is identical to the landing page.

## Routes (all public, `live_session :public`, `:mount_current_scope`)

| Path | Demo |
|---|---|
| `/demo` | **Hub** — cards linking each demo. |
| `/demo/review` | **Lifecycle** — one stepped flow (Submit → Review → Feedback → Discuss → Resolve) driven by a clickable step rail. Feedback/Discuss reuse the interactive workspace. |
| `/demo/earn` | Credits / referrals (Earn). |
| `/demo/billing` | Subscription plans + credit packs. |
| `/demo/history` | The reviews list. |

The current `/demo` workspace moves to `/demo/review` (as the Feedback/Discuss
steps of the stepped flow).

## Components & reuse

- `ReviewComponents.review_panes/1` — Feedback/Discuss steps (already shared with
  the real `WorkspaceLive`).
- `AppShell.app/1`, `chat_panel/1`, `workspace/1` — chrome.
- Existing hero keyframes in `app.css` (`pp-pdf-drop`, `pp-scan`, `pp-progress`,
  `pp-fill`, `pp-typing`, `pp-fade-up`, `pp-pop`, `pp-rail-*`) — reused for the
  Submit/Review/Resolve steps and the rail so demo motion == landing motion.
- `Billing.Prices` (via robust `plan_name/1`/`plan_price/1`-style access) for the
  billing demo; static data for the rest. No DB, no persistence.

## Microinteractions (editorial; all gated by `prefers-reduced-motion`)

Added as `pp-*` utility classes in `app.css`, applied in `review_components.ex` /
`chat_panel` / demo views:

- **Address** → a quiet check + the card settles into the addressed (success) state.
- **Dismiss** → the one-line minimized row fades/slides in (reads as collapsing).
- **Reply / chat message** → slide-up fade-in; a typing indicator precedes the
  bot's answer.
- **Archive** → fade-and-collapse out; the Archived count updates.
- **Show in the doc** → smooth scroll to the passage + a gold highlight pulse
  (CSS `:target`-driven where possible).
- **Open-count / step rail** → gentle transitions.

## Lifecycle stepped flow (`/demo/review`)

`step` assign (0–4) + a clickable rail (reusing `.pp-rail-*`). Per step:

0. **Submit** — dropzone + a PDF card that "drops" in (`pp-pdf-drop`).
1. **Review** — the manuscript with a scanning sweep (`pp-scan`) + a "Reading
   §3.2…" status pill; skeleton feedback.
2. **Feedback** — `review_panes` with the sample review (overall + detailed).
3. **Discuss** — same, chat column open; bot answers.
4. **Resolve** — comments addressed, a progress bar fills to 100% (`pp-fill`),
   "submission-ready", and an Export action.

Click-to-step (no auto-advance, to keep it deterministic/testable). All comment,
chat, thread, and archive interactivity from the current demo is preserved at the
Feedback/Discuss steps.

## Account-surface demos

- **`/demo/earn`** — referral link, credit balance, "ways to earn" cards, a
  ledger of recent credit events (static).
- **`/demo/billing`** — subscription plans + credit packs rendered from
  `Billing.Prices`, with a current-plan summary (static "Free" current plan).
- **`/demo/history`** — a list of past reviews (title, date, status, comment
  count) linking to `/demo/review`.

## Testing

ExUnit LiveView tests per page: mounts publicly (no auth), renders the key
content, and exercises the interactive bits (step rail navigation; existing
workspace interactions; billing renders plans; history lists reviews). Motion is
CSS — asserted by class presence, not animation.

## Out of scope

Real uploads/processing, persistence, auth, real payments — all stubbed/static.
No changes to the real authenticated app surfaces beyond what `review_panes`
already shares.
