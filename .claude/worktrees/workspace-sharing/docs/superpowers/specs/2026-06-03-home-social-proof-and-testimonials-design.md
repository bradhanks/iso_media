# Home Social Proof + Testimonials + Enterprise — Design

Date: 2026-06-03
Scope: cosmetic / marketing surface only. No context, schema, or business-logic
changes. Pure presentational LiveView-dead-view work on the public marketing pages.

## Goal

Add social proof and an enterprise page to the public site:

1. An **institution logo band** ("affiliation-honest" social proof) on the home
   page, directly under the hero.
2. A **testimonials page** at `/testimonials` with placeholder testimonials.
3. An **enterprise hub** at `/enterprise` — a single long-scroll page with
   anchored sections for each major enterprise area — plus **one dedicated
   in-depth page** at `/enterprise/security`. This is a deliberate IA choice: a
   long-scroll hub avoids thin/hollow per-area routes and consolidates SEO, while
   security earns its own route (depth + a page people deep-link and search for).
   - `/enterprise` hub sections (anchors): `#security` (summary → links to the
     dedicated page), `#teams`, `#access`, `#developers`, `#compliance`, `#support`
   - `/enterprise/security` — the in-depth security page

All follow the existing marketing-component pattern
(`lib/perfect_paper_web/components/marketing.ex` + `PageController` dead views)
and the `paper` daisyUI theme.

## Decisions (locked)

- **Logo band placement:** right under the hero, before `#how-it-works`.
- **Band framing:** affiliation-honest — these orgs fund/employ the founder
  (Deanna Kepka), they are not endorsing customers. Title copy avoids "Trusted by".
  Working title: **"Built by researchers funded by leading cancer-prevention
  institutions."** (final copy may be tuned during implementation; must stay
  affiliation-honest).
- **Institutions (4):** University of Utah · Huntsman Cancer Institute ·
  National Cancer Institute / NIH · American Cancer Society.
- **Logo sourcing:** source official **SVG** marks into
  `priv/static/images/institutions/`, normalized to a **uniform height** with a
  **grayscale + reduced-opacity** treatment (full opacity on hover) so mismatched
  brand colors read as one consistent set. **Fallback:** any logo without a clean
  official SVG gets a typeset monochrome wordmark SVG authored by us, so the band
  is never blocked or visually inconsistent.
- **Testimonials:** 3 placeholder cards, each with a **circular photo-placeholder
  avatar** (neutral placeholder, ready for real headshots), quote, name,
  position/title, institution.
- **Enterprise hub (long-scroll) + one security page.** `/enterprise` is a single
  page: a "Privacy, by design" headline, a 3-card security block (cards deep-link
  to `/enterprise/security` and the `#compliance` anchor), an in-page anchor nav,
  then one anchored section per area (`#security`, `#teams`, `#access`,
  `#developers`, `#compliance`, `#support`), and a "Contact sales" CTA → `/contact`.
  `/enterprise/security` is the one dedicated in-depth page.
- **Anchor nav is server-rendered, no JS.** These are dead views, so the in-page
  nav is plain anchor links (`<a href="#teams">`) — no LiveView JS hooks, no
  scrollspy/active-state JS. Discrete `id`s on sections exist for anchor targets
  and test assertions only.
- **Ground each section in shipped capability.** Each section describes what the
  codebase actually has, framed honestly:
  - **Security** — encryption in transit/at rest, content never used for training,
    Unicode input sanitization (`Security.UnicodeSanitizer`), retention & deletion.
  - **Teams** — `Organizations`: orgs, member roles, groups, invitations, shared
    credit pools (allocate/return/request).
  - **Access & identity** — `Accounts` SSO providers, org-enforced MFA
    (`set_mfa_required`), `Authz` access grants + scoped reads.
  - **Developers** — `ApiKeys`, the REST API, org-scoped `Webhooks` (HMAC-signed,
    delivery log, replay).
  - **Compliance & data** — retention/deletion, residency, subprocessors, and the
    **honest "pursuing" SOC 2 / ISO 27001 roadmap** — never assert as held.
  - **Support** — dedicated support, IT/help-desk resources, SLAs. This is a
    sales/marketing offering, not a shipped feature: phrased as "available on
    enterprise plans" with everything bespoke routing to "Contact sales".
- Anything bespoke or not-yet-built routes to "Contact sales" (`/contact`) rather
  than asserting a shipped capability. No vendor name is borrowed from the
  refine.ink example.

## Components

### `institution_logos/1` (new, in `marketing.ex`)

Presentational function component, daisyUI semantic classes + `paper` theme tokens.

- `attr :eyebrow` — default "Affiliations".
- `attr :heading` — default the affiliation-honest title above.
- `attr :logos, :list` — default the 4 institutions, each
  `%{name: String.t(), src: String.t(), alt: String.t()}` where `src` is a
  `~p"/images/institutions/<file>.svg"` path and `alt` the full institution name.
- `attr :class`, `attr :rest` — consistent with sibling components.

Markup: a `<section>` with hairline top/bottom borders (`border-base-300`),
`ds-container`, eyebrow + heading, then a centered logo row:
`grid grid-cols-2 sm:grid-cols-4 items-center gap-x-8 gap-y-10`. Each logo is an
`<img>` with `h-8 sm:h-9 w-auto object-contain` + a unifying treatment class
(grayscale + `opacity-70 hover:opacity-100 transition`). Every `<img>` has a
descriptive `alt`. No emoji. Sentence-case copy.

### `testimonial_card/1` (new, in `marketing.ex`)

- `attr :quote, :string, required: true`
- `attr :name, :string, required: true`
- `attr :title, :string, required: true` — position/title
- `attr :institution, :string, required: true`
- `attr :avatar_src, :string, default: nil` — placeholder image path; when nil,
  fall back to a daisyUI `avatar-placeholder` with the person's initials.

Markup: daisyUI `card` (`card bg-base-100 border border-base-300`), `card-body`
with the quote in `font-serif` (Newsreader, the long-form reading face), then a
footer row: circular `avatar` (photo placeholder) + name (`font-sans` semibold) /
title · institution (muted). Quote-forward, editorial, low-radius, flat — matches
theme.

### `security_card/1` (new, in `marketing.ex`)

A small presentational card for the enterprise privacy/security block, mirroring
the reference image: a soft rounded icon tile (daisyUI `hero-*` icon in a
`bg-primary/10 text-primary` square), a `card-title`, body copy in `font-serif`,
and an optional inline link (e.g. "Privacy Policy").

- `attr :icon, :string, required: true` — a `hero-*` icon name.
- `attr :title, :string, required: true`
- `attr :body, :string, required: true`
- `attr :link_label, :string, default: nil` / `attr :link_href, :string, default: nil`.

Used on the enterprise hub, the security page, and available to refresh the home
`#trust` section if desired (not required this pass).

### `enterprise_anchor_nav/1` (new, in `marketing.ex`)

An in-page anchor nav for the long-scroll hub: plain `<a href="#section">` links
(daisyUI `menu`/`tabs` styling, hairline border, `scroll-mt` offset on targets so
the sticky site header doesn't overlap). **Dead view → no JS, no scrollspy, no
active-state hooks.** Section `id`s double as anchor targets and test selectors.
The `/enterprise/security` page reuses it to link *back* to hub anchors plus a
"← Enterprise" link.

## Pages / routing

- **Home:** edit `page_html/home.html.heex` to render `<.institution_logos />`
  immediately after `<.hero ... />` and before the `#how-it-works` block.
- **Enterprise hub + security page:**
  - Router (public `scope "/"`):
    ```
    get "/enterprise",          PageController, :enterprise
    get "/enterprise/security", PageController, :enterprise_security
    ```
  - `PageController`: `enterprise/2` and `enterprise_security/2`, each thin.
  - Templates in `page_html/`: `enterprise.html.heex` (hub) and
    `enterprise_security.html.heex`, both wrapping `Layouts.app`.
  - **Hub** (`enterprise.html.heex`): (1) "Privacy, by design" eyebrow + headline;
    (2) 3 `security_card`s in `grid gap-6 md:grid-cols-3` — content-secure
    (→ `~p"/enterprise/security"`), never-used-for-training (→ `~p"/enterprise/security"`),
    compliance (honest "pursuing SOC 2 + ISO 27001" → `"#compliance"`);
    (3) `<.enterprise_anchor_nav>`; (4) one anchored `<section id="...">` per area
    (`security`, `teams`, `access`, `developers`, `compliance`, `support`) built
    from `security_card`/`feature_grid`, the `#security` section linking out to the
    dedicated page; (5) `cta_banner` "Contact sales" → `~p"/contact"`.
  - **Security page** (`enterprise_security.html.heex`): in-depth treatment of
    encryption in transit/at rest, content never used for training, Unicode input
    sanitization, retention & deletion, plus a back-link to `/enterprise`.
  - **Section content** lives in `PageHTML` helpers (like `faqs/0`):
    `enterprise_areas/0` (the per-section copy: id, title, blurb, bullet points,
    icon) and `enterprise_security_details/0` for the dedicated page.
  - Add an **Enterprise** link to the marketing nav and footer (`layouts.ex`)
    alongside the other public links.
- **Testimonials page:**
  - Router: add `get "/testimonials", PageController, :testimonials` in the public
    `scope "/"`.
  - `PageController`: add `testimonials/2` action rendering `:testimonials`.
  - `page_html/testimonials.html.heex`: `Layouts.app` wrapper, a heading section,
    then a responsive grid (`grid gap-6 md:grid-cols-3`) of `<.testimonial_card>`s
    fed by a `testimonials/0` helper in `PageHTML` (placeholder data, same pattern
    as the existing `faqs/0`).
  - Add a `/testimonials` link to the marketing footer/nav where the other public
    links (examples, contact) live.

## Assets

- `priv/static/images/institutions/` — 4 SVG logos, normalized.
- Photo-placeholder avatar: reuse a neutral placeholder (an existing brand icon
  asset or a small neutral SVG in `priv/static/images/`); real headshots swap in
  later by setting `avatar_src`.

## Testing (TDD, per CLAUDE.md)

Controller/markup tests only — no context tests needed (no context work).

- `PageControllerTest` (or page-html test):
  - `GET /` renders the institution band: asserts the affiliation-honest heading
    text and each institution `alt`/name is present; asserts it is NOT the
    "Trusted by" wording.
  - `GET /testimonials` returns 200 and renders all 3 placeholder names, titles,
    institutions, and quotes.
  - `GET /enterprise` returns 200, renders the "Privacy, by design" headline and
    all 3 security-card titles; the security cards link to `/enterprise/security`
    and the `#compliance` anchor; all six area sections render with their
    `id`s (`#security`, `#teams`, `#access`, `#developers`, `#compliance`,
    `#support`) and a grounded capability each (e.g. access mentions SSO/MFA,
    developers mentions webhooks/API keys); the "Contact sales" CTA links to
    `/contact`. The `#compliance` section uses honest "pursuing" wording — assert
    it does NOT claim a held SOC 2 / ISO 27001 certification.
  - `GET /enterprise/security` returns 200, renders the in-depth security headings
    (encryption, never-trained-on, input sanitization, retention/deletion) and the
    back-link to `/enterprise`.
- Follow discrete, unambiguous assertions (no multi-match selectors), per the
  LiveView quality bar.

Write the failing tests first (red), implement (green), refactor. Run only the
page controller test file while developing; full `mix precommit` only at pre-merge.

## Out of scope

- No real testimonials (placeholders only).
- No CMS / DB-backed testimonials or logos (static helpers, like `faqs/0`).
- No changes to any context, schema, or API.
- No motion animation in this work — only a simple `hover:opacity` crossfade on the
  logos, which is not the transform/parallax motion `prefers-reduced-motion`
  governs, so no reduced-motion handling is needed here.
- Enterprise hub + security page are **marketing copy only** — no new SSO/SAML, billing,
  provisioning, support-desk, or SLA systems are built this pass. Sections
  *describe* capabilities the codebase already has (orgs, roles, groups, SSO,
  MFA, authz grants, API keys, webhooks); anything bespoke or not-yet-built
  (e.g. SLAs, dedicated support) routes to "Contact sales" (`/contact`) and is
  phrased as an enterprise-plan offering. No compliance certification is asserted
  as held.

## Risks / notes

- **Trademark/endorsement:** real institutional marks are used as affiliation
  signals, not endorsements; copy is worded accordingly. If brand-usage becomes a
  concern, swap to typeset wordmarks (the fallback already produces these).
- **Logo availability:** if official SVGs are not cleanly fetchable, the typeset
  wordmark fallback keeps the band uniform and unblocked.
- **Placeholder testimonials are public + indexed (accepted risk):** shipping a
  public `/testimonials` with placeholder data was raised as a perceived-legitimacy
  risk; the decision is to ship it as a normal indexed page now and replace the
  placeholders with real quotes when available. (No `noindex` per that decision.)
