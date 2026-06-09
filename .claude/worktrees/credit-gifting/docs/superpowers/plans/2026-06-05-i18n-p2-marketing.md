# i18n P2 — Marketing String Extraction Plan

**Goal:** Make the public marketing surface fully translatable by wrapping its user-visible strings in `gettext/1`, then ship German (`de`) drafts as the reference locale.

**Approach:** Mechanical extraction, guarded by the existing `PageControllerTest` (English msgids render unchanged when locale is `en`, so those assertions must stay green). Execute in surface groups via sequential subagents in the main worktree (one writer at a time — isolated parallel worktrees proved unreliable here). After extraction, `mix gettext.extract` + draft `de`.

**Scope decisions:**
- **In:** Layouts header/footer, cookie-consent remaining strings, locale switcher aria; `home.html.heex` + `marketing.ex` + `marketing/{hero,pricing,content,editorial}_components.ex`; `examples`, `contact`, `testimonials`, `enterprise`, `enterprise_security`.
- **Out:** the long legal bodies of `privacy.html.heex` / `terms.html.heex` — whole-document legal text is localized as complete professionally-translated documents, NOT fragmented into msgids. Tracked as a separate effort.
- **Translations:** German drafts only this pass (flagged `fuzzy`/needs-review). The other 10 locales fall back to English and are a dedicated translation-content follow-up.

**Extraction rules (quality bar):**
- Wrap whole user-visible sentences/labels: `{gettext("Expert feedback on your manuscript")}`. Never split a sentence across calls.
- Preserve interpolation with bindings: `gettext("Used %{count} credits", count: @n)` — not string concatenation.
- Do NOT wrap: route sigils (`~p`), class names, `data-*`/`id`/`aria` *values* that aren't shown to users (DO wrap human-readable `aria-label` text), brand tokens ("PerfectPaper"), or dynamic data already coming from a context.
- Inside `<script>` tags, `gettext` does not interpolate — leave those alone (none expected in marketing copy).
- HEEx text nodes: `{gettext("...")}`. Attributes: `aria-label={gettext("...")}`.

**Per-group loop:** wrap strings → `MIX_TEST_PARTITION=eu mix test test/perfect_paper_web/controllers/page_controller_test.exs` (stays green) → `mix compile --warnings-as-errors` → commit.

**Tasks:** P2.1 chrome · P2.2 home+components · P2.3 examples/contact/testimonials/enterprise · P2.4 extract+de drafts+smoke test · P2.5 precommit+merge.

**Verification:** existing page tests prove English is unchanged; a new `marketing_i18n_test` asserts a few `de` strings render and English falls back. Full `mix precommit` before merge.
