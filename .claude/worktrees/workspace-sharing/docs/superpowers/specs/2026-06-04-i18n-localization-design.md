# Design: Internationalization & Localization (i18n)

**Date:** 2026-06-04
**Status:** Approved for planning
**Sub-project:** C of the European-compliance initiative (A cookie-consent shipped; B abuse-controls dropped → Cloudflare)
**Worktree/branch:** `worktree-european-compliance`

## Summary

Make PerfectPaper multilingual across both the public marketing site and the
authenticated app, for **12 locales**. Localization happens through **two
distinct mechanisms** driven by **one shared locale value**:

1. **Static UI text** (buttons, headings, marketing copy, cookie banner, settings
   labels) → **Gettext** catalogs. Claude-drafted translations, flagged for
   native review before public launch.
2. **AI-generated review feedback** (the proofreading comments themselves) → **not
   translated as strings**; instead the user's locale is threaded into the
   `Chatbot.LLM` request and the model is instructed to respond only in that
   language.

The locale value resolves from a single precedence chain (below) so the two
mechanisms never disagree.

## Goals

- A visitor's locale is auto-detected and can be changed via a clean **globe-icon
  language switcher** (dropdown of native language names) in both the marketing
  header and the app shell.
- A new account's default locale is snapshotted from `Accept-Language` at signup;
  logged-in users can change it in settings, and it persists.
- Every static string on marketing pages **and** app LiveViews renders through
  Gettext.
- AI review/chat output is written in the user's language.

## Non-goals (this sub-project)

- Professional/native translation review (we ship Claude drafts flagged
  `fuzzy`/needs-review; review is an operational follow-up, not code).
- URL-prefixed locale routing (`/de`, `/fr`) — explicitly rejected in favor of
  cookie + `Accept-Language` + user setting (see Decisions).
- RTL layout support (none of the 12 locales are RTL).
- Localized number/date/currency formatting beyond what Gettext plural rules give
  us (billing amounts stay as-is this pass).
- Data residency, DSAR surface (sub-projects D and E).

## Locale set (12)

| Code | Language | Notes |
|------|----------|-------|
| `en` | English | **Default / source language** |
| `en-GB` | English (UK) | Variant → falls back to `en` |
| `de` | German | |
| `fr` | French (France) | |
| `fr-CA` | French (Canada) | Variant → falls back to `fr` |
| `es` | Spanish (Spain) | |
| `es-MX` | Spanish (Latin America) | Variant → falls back to `es` |
| `nl` | Dutch | |
| `it` | Italian | |
| `hi` | Hindi | |
| `ru` | Russian | |
| `ro` | Romanian | |

Variants store only the strings that differ from their base; everything else
falls back to the base language, then to the English source. The supported list,
native display names, and base-fallback mapping live in **one place**:
`PerfectPaper.Localization` (config-as-code, like `Credits.Tier` /
`Billing.Prices`).

## Decisions (and rationale)

- **No URL prefixes.** Locale comes from cookie + `Accept-Language` + user
  setting. Simpler, no rewrite of every route/link. Trade-off: weaker
  per-language SEO and no shareable per-language URLs — acceptable for this
  product, and reversible later if SEO demands it.
- **Globe icon, not flags.** Flags represent countries, not languages (Spanish
  has no single flag), are an i18n anti-pattern, and would violate the no-emoji
  rule / require 12 SVG assets. The switcher shows a `hero-language`/globe icon +
  the current short code; the dropdown lists **native names** (Deutsch, Français,
  Español, …).
- **Two mechanisms, one locale.** Gettext for fixed text; LLM prompt directive for
  generated text. Both read the same resolved locale.
- **Claude-drafted catalogs, flagged.** Catalogs ship populated but marked
  `#, fuzzy` so a later native-review pass is unambiguous. The spec and PR will
  state plainly these are machine drafts.

## Locale resolution (single source of truth)

New context **`PerfectPaper.Localization`**:

- `supported_locales/0` → list of `%{code, language, native_name, base}`.
- `default_locale/0` → `"en"`.
- `known?/1`, `base_of/1`, `native_name/1`.
- `negotiate(accept_language_header)` → best supported locale. Implemented with
  no new dependency: parse the header's `q`-weighted entries and match against the
  supported codes, then their base codes (`fr-CA`→`fr`), then `default_locale/0`.
- `resolve(opts)` → applies the precedence chain.

**Precedence chain:**

1. **Logged-in user** → `users.locale` is authoritative (the switcher writes to
   it).
2. **Anonymous** → `pp_locale` cookie, else negotiated `Accept-Language`, else
   `default_locale/0`.

This is the only place the precedence lives; the plug and the LiveView `on_mount`
both call it.

### Web wiring

- **`PerfectPaperWeb.Plugs.FetchLocale`** (in the `:browser` pipeline, after
  `fetch_current_scope_for_user`): calls `Localization.resolve/1`, then
  `Gettext.put_locale(PerfectPaperWeb.Gettext, locale)`, and `assign(:locale, …)`.
- **`PerfectPaperWeb.UserAuth.on_mount(:load_locale, …)`**: mirrors the plug for
  LiveViews — reads the locale from the session/cookie + current scope, calls
  `Gettext.put_locale`, assigns `:locale`. Added to the relevant `live_session`
  `on_mount` chains (public, current_user, require_authenticated).
- **`renew_session/2`** in `user_auth.ex`: preserve `:preferred_locale` across
  session renewal (the template comment that's already there).

### The switcher endpoint

`PerfectPaperWeb.LocaleController` (mirrors the cookie-consent controller pattern):

- `PUT/POST /locale` with `locale` + open-redirect-guarded `return_to`.
- Validates against `Localization.known?/1` (unknown → ignored).
- Sets the `pp_locale` cookie (1 year, SameSite=Lax).
- If logged in, also persists via `Accounts.update_user_locale(user, locale)`.
- Redirects back to `return_to`.

### The switcher component

`PerfectPaperWeb.LocaleSwitcher.switcher/1` — a daisyUI dropdown: globe icon +
current code button, dropdown of native names posting to `/locale`. Rendered in
both `Layouts.site_header/1` (marketing) and `AppShell` header actions (app).
Accessible (labelled control, keyboard-navigable), reduced-motion respected.

## AI feedback localization

`Chatbot.LLM` behaviour and adapters (`Chatbot.LLM.Anthropic`, `Chatbot.LLM.Stub`)
extended to accept the locale:

- `@callback review(text, level, opts)` and `@callback complete(messages, opts)`
  where `opts` carries `:locale` (keyword/map; default `en`). Extending with an
  `opts` map keeps the change additive and avoids a positional explosion.
- The adapter appends a **language directive** to its system prompt, e.g.:
  *"Write all overall feedback and comments to the author in {native_name}
  ({code}). Use natural, idiomatic phrasing a native speaker would use; do not
  translate technical terms that are conventionally left in English."*
- `PerfectPaper.Chatbot` reads the locale from the acting user/scope (review and
  chat are authenticated) and passes it down. No vendor specifics leak — it's
  prompt content only, behind the existing anti-corruption boundary.
- The directive text itself is built from `Localization.native_name/1`; it is
  English instruction text to the model (not user-facing), so it does **not** go
  through Gettext.

## Static string extraction (Gettext)

- Configure Gettext: `config :gettext, :default_locale, "en"`; locale dirs created
  for all 12 codes under `priv/gettext/<locale>/LC_MESSAGES/`.
- Wrap every hardcoded English user-facing string across:
  - **Marketing:** `page_html/*.heex` (home, examples, contact, terms, privacy,
    testimonials, enterprise, enterprise_security), `Layouts` header/footer, the
    cookie-consent components + settings page, `LocaleSwitcher`.
  - **App:** all authenticated LiveViews (new/review, history index+show,
    workspace, account, billing, earn, webhooks, sso, scim, settings, admin
    credits) and `AppShell` chrome, plus shared `CoreComponents` strings.
- Use `gettext/1`, `ngettext/3` for plurals, and `dgettext`/domains where a page
  has a large distinct block (e.g. `marketing`, `errors` already exists).
- `mix gettext.extract --merge` to produce `.pot` + merge into the 12 `.po`
  catalogs.
- Populate non-English catalogs with Claude-drafted translations marked `fuzzy`.

### Quality bar for extraction

- Preserve interpolation: `gettext("Hello %{name}", name: @user.name)` — never
  split a sentence across multiple `gettext` calls.
- Keep `~p` route sigils and HEEx attributes out of message strings.
- Don't translate brand tokens: "PerfectPaper" stays one word, untranslated.
- Respect existing copy rules (sentence case, scholarly voice) in the English
  source; drafts mirror register per locale.

## Data model

Migration: `add :locale, :string, null: false, default: "en"` to `users`.

- `User` schema: `field :locale, :string, default: "en"`; add to `@type`.
- `User.locale_changeset/2` (pure): casts `:locale`, validates inclusion in
  `Localization.supported_locales/0` codes.
- `Accounts.update_user_locale/2` — context API for the switcher + settings.
- Registration: `normal_register_user*/1` set `:locale` from the resolved request
  locale. The registration LiveViews pass the resolved locale (from assigns) into
  the attrs so the default is the `Accept-Language`-negotiated value.

## Settings UI

`UserLive.Settings`: add a **Language** section — a `select` of native names bound
to a `locale_changeset`, submitting through `Accounts.update_user_locale/2`. On
success, also set the `pp_locale` cookie (via a controller round-trip or
`push_navigate` so the dead-render plug re-reads it) and re-render in the new
language.

## Phasing (implementation order; design covers all)

Each phase is its own plan, merges to `main` green, and is independently useful.

- **P1 — Foundation + AI language.** `Localization` context, `FetchLocale` plug +
  `:load_locale` on_mount, `users.locale` migration + changeset + registration
  default, `LocaleController` + `LocaleSwitcher`, settings Language section, and
  the `Chatbot.LLM` locale threading. Gettext configured for all 12 locales.
  Proven by localizing one small surface (the cookie banner + site header/footer)
  end-to-end, including the switcher actually changing language.
- **P2 — Marketing extraction + catalogs.** Extract all marketing-page strings;
  draft all 12 catalogs for that domain.
- **P3 — App extraction + catalogs.** Extract all authenticated-LiveView strings;
  draft catalogs for the app domain.

## Testing strategy

- **`Localization` context** (pure, async): negotiation from assorted
  `Accept-Language` headers, base fallback (`fr-CA`→`fr`), `known?`, precedence in
  `resolve/1` for logged-in vs anonymous.
- **`FetchLocale` plug / on_mount** (ConnCase): `Accept-Language` sets locale;
  `pp_locale` cookie overrides; logged-in `users.locale` overrides; unknown
  values ignored → default.
- **`LocaleController`** (ConnCase): sets cookie; persists `users.locale` when
  logged in; open-redirect guard; unknown locale rejected.
- **Switcher render** (ConnCase/LiveView): globe icon + native names present in
  marketing and app headers; current locale marked.
- **Gettext**: a representative page asserts a known translated string renders in
  a non-English locale (using a seeded catalog entry), and that an untranslated
  string falls back to English.
- **Chatbot locale**: the Stub adapter receives `:locale` in `opts`; a unit test
  asserts the Anthropic adapter's assembled system prompt includes the language
  directive for a given locale. (No real API calls — Stub only.)
- **Registration**: a signup with a German `Accept-Language` persists
  `users.locale == "de"`.

All test runs use `MIX_TEST_PARTITION` to stay isolated from parallel agents.
TDD throughout: red → green → refactor.

## Risks / watch-items

- **Translation credibility.** Machine drafts must not be mistaken for
  launch-ready in a medical/academic context. Mitigation: `fuzzy` markers + an
  explicit note in each PR; native review tracked as an operational follow-up.
- **String-extraction blast radius.** Touching every LiveView is large and
  error-prone. Mitigation: phased (P2/P3), and lean on a workflow/systematic pass
  per file with tests guarding rendering.
- **HEEx gotcha.** `<script>` bodies render verbatim and `{...}` interpolation is
  inert inside them (learned in sub-project A); irrelevant to Gettext but noted
  for any inline JS the switcher might need (prefer a hook/`document` cookie set
  server-side — the controller round-trip avoids inline JS entirely).
- **Variant fallback.** Confirm Gettext serves base-language strings for variant
  locales where the variant catalog has no entry; if Gettext won't fall back
  `fr-CA`→`fr` natively, `Localization.base_of/1` drives a second `put_locale`
  lookup or we seed variants fully. Resolved in P1.
```
