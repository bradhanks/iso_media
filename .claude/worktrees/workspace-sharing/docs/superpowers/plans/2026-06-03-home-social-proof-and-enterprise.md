# Home Social Proof + Testimonials + Enterprise Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an institution logo band under the home hero, a public `/testimonials` page (placeholders), and an enterprise hub at `/enterprise` (long-scroll, anchored sections) plus a dedicated in-depth `/enterprise/security` page.

**Architecture:** Pure presentational work on the existing `PageController` dead-view + `PerfectPaperWeb.Marketing` (flat module) pattern, styled with the `paper` daisyUI theme and the shared `ds-container`. New components live in `lib/perfect_paper_web/components/marketing.ex` alongside `hero/feature_grid/cta_banner`. Content is static `PageHTML` helpers (same pattern as `faqs/0`). No context, schema, API, or JS changes.

**Tech Stack:** Elixir/Phoenix 1.8, HEEx function components, Tailwind v4 + daisyUI, ExUnit `ConnCase`.

**Spec:** `docs/superpowers/specs/2026-06-03-home-social-proof-and-testimonials-design.md`

---

## Conventions (read once before starting)

- **Components module:** `PerfectPaperWeb.Marketing` in `lib/perfect_paper_web/components/marketing.ex`. It is already imported into every `:html`/controller view (`lib/perfect_paper_web.ex:92`), so new functions there are callable as `<.name />` in any `page_html/*.html.heex` template with no extra import.
- **Icons:** `<.icon name="hero-..." class="..." />` from `CoreComponents` is available in templates and in `marketing.ex` (it's a `Phoenix.Component`). Use heroicons names (e.g. `hero-lock-closed`, `hero-shield-check`, `hero-no-symbol`, `hero-users`, `hero-key`, `hero-document-check`, `hero-lifebuoy`).
- **Container:** use `ds-container` for page-width sections (matches the home page). **Do not** introduce `max-w-7xl` or `max-w-6xl` on the home page — `PageControllerTest` asserts `GET /` contains neither.
- **Typography:** `font-display` (Fraunces) headlines, `font-serif` (Newsreader) body/quotes, `font-sans` (Outfit) labels/UI. Helpers `.ds-h2`, eyebrow style `font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary`.
- **Theme:** daisyUI semantic classes only (`bg-base-100`, `border-base-300`, `text-primary`). No raw Tailwind palette colors. No emoji. Sentence case. Always "PerfectPaper".
- **Run a single test file** while developing (e.g. `mix test test/perfect_paper_web/controllers/page_controller_test.exs`). Reserve `mix precommit` for the final pre-merge task.
- **Commit** after every green step listed below.

---

## Task 0: Create the feature branch

- [ ] **Step 1: Cut a fresh branch off `main`**

The repo's current branch is `feat/collaborative-commenting`. Per CLAUDE.md, branch off `main`.

Run:
```bash
git checkout main && git pull --ff-only && git checkout -b feat/home-social-proof-enterprise
```
Expected: now on `feat/home-social-proof-enterprise`.

> If `main` is checked out in another worktree and `git checkout main` fails, instead branch from the local `main` ref without switching: `git fetch . && git checkout -b feat/home-social-proof-enterprise main`. Do not cut the branch off `feat/collaborative-commenting`.

---

## Task 1: Institution logo band on the home page

**Files:**
- Create: `priv/static/images/institutions/university-of-utah.svg`
- Create: `priv/static/images/institutions/huntsman-cancer-institute.svg`
- Create: `priv/static/images/institutions/national-cancer-institute.svg`
- Create: `priv/static/images/institutions/american-cancer-society.svg`
- Modify: `lib/perfect_paper_web/components/marketing.ex` (add `institution_logos/1`)
- Modify: `lib/perfect_paper_web/controllers/page_html/home.html.heex` (render band under hero)
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs`

### Logo assets

We need four uniform marks. **Baseline deliverable: authored monochrome wordmark SVGs** (uniform by construction, no network dependency, no trademark-art risk). They render via `<img>`, so text uses a system serif and an explicit `fill` (an `<img>`-referenced SVG cannot inherit page web-fonts or `currentColor`). The component applies `grayscale` + opacity so all four read as one set. Official brand SVGs can later overwrite these same filenames without touching the component.

> Optional during execution: try to fetch an official SVG, e.g. `curl -fsSL <url> -o priv/static/images/institutions/<file>.svg`. If the result isn't a clean single-color SVG at a sane size, discard it and keep the authored wordmark below. Do not block on fetching.

- [ ] **Step 1: Create the four wordmark SVGs**

`priv/static/images/institutions/university-of-utah.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 260 40" width="260" height="40" role="img" aria-label="University of Utah">
  <text x="0" y="28" font-family="Georgia, 'Times New Roman', serif" font-size="26" font-weight="600" letter-spacing="0.5" fill="#211c18">University of Utah</text>
</svg>
```

`priv/static/images/institutions/huntsman-cancer-institute.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 330 40" width="330" height="40" role="img" aria-label="Huntsman Cancer Institute">
  <text x="0" y="28" font-family="Georgia, 'Times New Roman', serif" font-size="26" font-weight="600" letter-spacing="0.5" fill="#211c18">Huntsman Cancer Institute</text>
</svg>
```

`priv/static/images/institutions/national-cancer-institute.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 40" width="320" height="40" role="img" aria-label="National Cancer Institute">
  <text x="0" y="28" font-family="Georgia, 'Times New Roman', serif" font-size="26" font-weight="600" letter-spacing="0.5" fill="#211c18">National Cancer Institute</text>
</svg>
```

`priv/static/images/institutions/american-cancer-society.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 310 40" width="310" height="40" role="img" aria-label="American Cancer Society">
  <text x="0" y="28" font-family="Georgia, 'Times New Roman', serif" font-size="26" font-weight="600" letter-spacing="0.5" fill="#211c18">American Cancer Society</text>
</svg>
```

- [ ] **Step 2: Write the failing test**

Add to `test/perfect_paper_web/controllers/page_controller_test.exs`, inside the top-level test block (after the existing `GET /` tests):

```elixir
  test "GET / renders the institution affiliation band", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    # Affiliation-honest heading (NOT "Trusted by" — the hero already uses that
    # phrase for its own row, so we assert the band's own copy instead).
    assert body =~ "funded by leading cancer-prevention institutions"

    # Each institution renders as an <img> with a descriptive alt.
    assert body =~ ~s(alt="University of Utah")
    assert body =~ ~s(alt="Huntsman Cancer Institute")
    assert body =~ ~s(alt="National Cancer Institute")
    assert body =~ ~s(alt="American Cancer Society")

    # Served from the institutions asset folder, and stays on the shared container.
    assert body =~ "/images/institutions/university-of-utah.svg"
    assert body =~ ~s(id="affiliations")
  end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: FAIL (heading/alt strings not found).

- [ ] **Step 4: Add the `institution_logos/1` component**

Append to `lib/perfect_paper_web/components/marketing.ex`, before the final `end`:

```elixir
  @doc """
  An "affiliation-honest" social-proof band: a row of institution wordmarks shown
  at a uniform height with a unifying grayscale + opacity treatment. These mark
  the institutions that fund/employ the team, not endorsing customers — copy is
  worded accordingly (no "trusted by"/endorsement claim).

  ## Examples

      <.institution_logos />
  """
  attr :eyebrow, :string, default: "Affiliations"

  attr :heading, :string,
    default: "Built by researchers funded by leading cancer-prevention institutions"

  attr :logos, :list,
    default: [
      %{src: "/images/institutions/university-of-utah.svg", alt: "University of Utah"},
      %{src: "/images/institutions/huntsman-cancer-institute.svg", alt: "Huntsman Cancer Institute"},
      %{src: "/images/institutions/national-cancer-institute.svg", alt: "National Cancer Institute"},
      %{src: "/images/institutions/american-cancer-society.svg", alt: "American Cancer Society"}
    ]

  attr :class, :string, default: nil
  attr :rest, :global

  def institution_logos(assigns) do
    ~H"""
    <section
      id="affiliations"
      class={["border-y border-base-300 bg-base-200/40 py-12 lg:py-16", @class]}
      {@rest}
    >
      <div class="ds-container">
        <p class="font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary text-center">
          {@eyebrow}
        </p>
        <h2 class="ds-h3 mt-2 mb-8 max-w-2xl mx-auto text-center font-display font-semibold">
          {@heading}
        </h2>
        <ul class="grid grid-cols-2 items-center justify-items-center gap-x-8 gap-y-10 sm:grid-cols-4">
          <li :for={logo <- @logos} class="flex items-center justify-center">
            <img
              src={logo.src}
              alt={logo.alt}
              loading="lazy"
              class="h-8 w-auto object-contain opacity-60 grayscale transition hover:opacity-100 sm:h-9"
            />
          </li>
        </ul>
      </div>
    </section>
    """
  end
```

- [ ] **Step 5: Render the band under the hero**

In `lib/perfect_paper_web/controllers/page_html/home.html.heex`, insert immediately after the closing `/>` of `<.hero ... />` (currently lines 2–5) and before `<div id="how-it-works">`:

```heex
  <.institution_logos />

```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS.

- [ ] **Step 7: Verify the home page didn't regress its container rules**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS (including the existing "lines every section up on one shared page container" test — the new band uses `ds-container`, no `max-w-6xl`/`max-w-7xl`).

- [ ] **Step 8: Commit**

```bash
git add priv/static/images/institutions lib/perfect_paper_web/components/marketing.ex lib/perfect_paper_web/controllers/page_html/home.html.heex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(marketing): institution affiliation logo band under home hero"
```

---

## Task 2: Testimonials page (`/testimonials`)

**Files:**
- Create: `priv/static/images/avatar-placeholder.svg`
- Modify: `lib/perfect_paper_web/components/marketing.ex` (add `testimonial_card/1`)
- Modify: `lib/perfect_paper_web/router.ex` (add route)
- Modify: `lib/perfect_paper_web/controllers/page_controller.ex` (add action)
- Modify: `lib/perfect_paper_web/controllers/page_html.ex` (add `testimonials/0`)
- Create: `lib/perfect_paper_web/controllers/page_html/testimonials.html.heex`
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs`

> Note on reuse: `ContentComponents.testimonial_grid/1` already exists but renders **initials** (not the requested photo placeholder), folds title+institution into one `affiliation` string, and uses a bespoke `max-w-6xl px-5` gutter instead of `ds-container`. We add a distinct `testimonial_card/1` in the flat `Marketing` module to match the approved spec (photo placeholder, separate title/institution) and the home-page container idiom.

- [ ] **Step 1: Create the neutral photo placeholder avatar**

`priv/static/images/avatar-placeholder.svg`:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="96" height="96" role="img" aria-label="">
  <rect width="96" height="96" fill="#ece6da"/>
  <circle cx="48" cy="38" r="17" fill="#b8ad99"/>
  <path d="M16 86c0-17.7 14.3-32 32-32s32 14.3 32 32z" fill="#b8ad99"/>
</svg>
```

- [ ] **Step 2: Write the failing test**

Add to `test/perfect_paper_web/controllers/page_controller_test.exs`:

```elixir
  describe "GET /testimonials" do
    test "renders the placeholder testimonials", %{conn: conn} do
      body = conn |> get(~p"/testimonials") |> html_response(200)

      assert body =~ "What researchers say"

      # All three placeholder people render name, title, institution, quote.
      assert body =~ "Dr. Jordan Avery"
      assert body =~ "Associate Professor of Epidemiology"
      assert body =~ "University of Utah"
      assert body =~ "turned a dreaded revision cycle"

      assert body =~ "Dr. Priya Nair"
      assert body =~ "Postdoctoral Research Fellow"

      assert body =~ "Marcus Bennett"
      assert body =~ "PhD Candidate, Population Health"

      # Photo-placeholder avatar slot is present.
      assert body =~ "/images/avatar-placeholder.svg"
    end
  end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: FAIL (no route `/testimonials`).

- [ ] **Step 4: Add the `testimonial_card/1` component**

Append to `lib/perfect_paper_web/components/marketing.ex`, before the final `end`:

```elixir
  @doc """
  A single testimonial: a serif pull-quote above a footer with a circular avatar,
  the person's name, their title, and their institution. Pass `avatar_src` for a
  photo (or photo placeholder); when nil it falls back to a daisyUI initials
  avatar built from `name`.

  ## Examples

      <.testimonial_card
        quote="PerfectPaper caught gaps two reviewers missed."
        name="Dr. Jordan Avery"
        title="Associate Professor of Epidemiology"
        institution="University of Utah"
        avatar_src="/images/avatar-placeholder.svg"
      />
  """
  attr :quote, :string, required: true
  attr :name, :string, required: true
  attr :title, :string, required: true
  attr :institution, :string, required: true
  attr :avatar_src, :string, default: nil
  attr :class, :string, default: nil

  def testimonial_card(assigns) do
    ~H"""
    <figure class={["card flex flex-col border border-base-300 bg-base-100", @class]}>
      <div class="card-body gap-6">
        <blockquote class="flex-1 font-serif text-[1.05rem] italic leading-relaxed text-base-content/85">
          "{@quote}"
        </blockquote>
        <figcaption class="flex items-center gap-3.5 border-t border-base-300 pt-5">
          <div :if={@avatar_src} class="avatar">
            <div class="w-11 rounded-full">
              <img src={@avatar_src} alt={@name} loading="lazy" />
            </div>
          </div>
          <div :if={!@avatar_src} class="avatar avatar-placeholder">
            <div class="w-11 rounded-full bg-primary/10 text-primary">
              <span class="font-sans text-sm font-semibold">{initials(@name)}</span>
            </div>
          </div>
          <span class="leading-tight">
            <span class="block font-sans text-sm font-semibold text-base-content">{@name}</span>
            <span class="block font-sans text-xs text-base-content/60">
              {@title} · {@institution}
            </span>
          </span>
        </figcaption>
      </div>
    </figure>
    """
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&String.ends_with?(&1, "."))
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end
```

- [ ] **Step 5: Add placeholder content to `PageHTML`**

In `lib/perfect_paper_web/controllers/page_html.ex`, add before the final `end`:

```elixir
  @doc false
  # Placeholder testimonials for the public /testimonials page. Replace `quote`
  # text and swap `avatar_src` for real headshots when available.
  def testimonials do
    [
      %{
        quote:
          "PerfectPaper turned a dreaded revision cycle into an afternoon. It flagged an unsupported claim in my methods that two human reviewers had missed.",
        name: "Dr. Jordan Avery",
        title: "Associate Professor of Epidemiology",
        institution: "University of Utah",
        avatar_src: "/images/avatar-placeholder.svg"
      },
      %{
        quote:
          "The comments read like a thoughtful colleague's, not a grammar checker's. Every note pointed to the exact passage and explained why it mattered.",
        name: "Dr. Priya Nair",
        title: "Postdoctoral Research Fellow",
        institution: "Huntsman Cancer Institute",
        avatar_src: "/images/avatar-placeholder.svg"
      },
      %{
        quote:
          "I sent my first-author manuscript through before submission and walked in far more confident. Worth it for the consistency checks alone.",
        name: "Marcus Bennett",
        title: "PhD Candidate, Population Health",
        institution: "American Cancer Society Fellow",
        avatar_src: "/images/avatar-placeholder.svg"
      }
    ]
  end
```

- [ ] **Step 6: Add the route**

In `lib/perfect_paper_web/router.ex`, in the public `scope "/", PerfectPaperWeb do` block, after the `get "/privacy", PageController, :privacy` line:

```elixir
    get "/testimonials", PageController, :testimonials
```

- [ ] **Step 7: Add the controller action**

In `lib/perfect_paper_web/controllers/page_controller.ex`, before the final `end`:

```elixir
  def testimonials(conn, _params) do
    render(conn, :testimonials)
  end
```

- [ ] **Step 8: Create the template**

`lib/perfect_paper_web/controllers/page_html/testimonials.html.heex`:
```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <section class="ds-container py-16 lg:py-24">
    <div class="mb-10 max-w-2xl">
      <p class="font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary">
        Testimonials
      </p>
      <h1 class="ds-h2 mt-2">What researchers say</h1>
      <p class="mt-4 font-serif text-base-content/70">
        Early feedback from researchers who put their manuscripts through PerfectPaper
        before submission.
      </p>
    </div>

    <div class="grid gap-6 md:grid-cols-3">
      <.testimonial_card
        :for={t <- testimonials()}
        quote={t.quote}
        name={t.name}
        title={t.title}
        institution={t.institution}
        avatar_src={t.avatar_src}
      />
    </div>
  </section>
</Layouts.app>
```

- [ ] **Step 9: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add priv/static/images/avatar-placeholder.svg lib/perfect_paper_web/components/marketing.ex lib/perfect_paper_web/router.ex lib/perfect_paper_web/controllers/page_controller.ex lib/perfect_paper_web/controllers/page_html.ex lib/perfect_paper_web/controllers/page_html/testimonials.html.heex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(marketing): public /testimonials page with placeholder cards"
```

---

## Task 3: Enterprise shared components (`security_card`, `enterprise_anchor_nav`)

**Files:**
- Modify: `lib/perfect_paper_web/components/marketing.ex` (add two components)
- Test: `test/perfect_paper_web/components/marketing_test.exs` (create if absent)

- [ ] **Step 1: Write the failing component test**

Create `test/perfect_paper_web/components/marketing_test.exs` (or add to it if it exists):

```elixir
defmodule PerfectPaperWeb.MarketingTest do
  use PerfectPaperWeb.ConnCase, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PerfectPaperWeb.Marketing

  test "security_card renders icon tile, title, body, and optional link" do
    html =
      render_component(&security_card/1, %{
        icon: "hero-lock-closed",
        title: "Your content is secure",
        body: "Encrypted in transit and at rest.",
        link_label: "Read our security page",
        link_href: "/enterprise/security"
      })

    assert html =~ "Your content is secure"
    assert html =~ "Encrypted in transit and at rest."
    assert html =~ "Read our security page"
    assert html =~ ~s(href="/enterprise/security")
  end

  test "enterprise_anchor_nav renders plain anchor links with no JS hooks" do
    html =
      render_component(&enterprise_anchor_nav/1, %{
        links: [{"Teams", "#teams"}, {"Developers", "#developers"}]
      })

    assert html =~ ~s(href="#teams")
    assert html =~ ~s(href="#developers")
    assert html =~ "Teams"
    # Dead view: must not wire any LiveView JS hook.
    refute html =~ "phx-hook"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/components/marketing_test.exs`
Expected: FAIL (`security_card`/`enterprise_anchor_nav` undefined).

- [ ] **Step 3: Add the components**

Append to `lib/perfect_paper_web/components/marketing.ex`, before the final `end`:

```elixir
  @doc """
  A privacy/security feature card: a soft rounded icon tile, a title, body copy,
  and an optional inline link. Used on the enterprise hub and security page.

  ## Examples

      <.security_card
        icon="hero-lock-closed"
        title="Your content is secure"
        body="Encrypted in transit and at rest."
        link_label="Privacy policy"
        link_href="/privacy"
      />
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  attr :link_label, :string, default: nil
  attr :link_href, :string, default: nil
  attr :class, :string, default: nil

  def security_card(assigns) do
    ~H"""
    <div class={["card border border-base-300 bg-base-100", @class]}>
      <div class="card-body gap-3">
        <span class="grid size-11 place-items-center rounded-xl bg-primary/10 text-primary">
          <.icon name={@icon} class="size-5" />
        </span>
        <h3 class="card-title font-display text-lg">{@title}</h3>
        <p class="font-serif text-sm leading-relaxed text-base-content/70">{@body}</p>
        <a :if={@link_label && @link_href} href={@link_href} class="link link-primary font-sans text-sm font-semibold">
          {@link_label}
        </a>
      </div>
    </div>
    """
  end

  @doc """
  In-page anchor nav for the long-scroll enterprise hub. Plain server-rendered
  `<a href="#...">` links — these are dead views, so there is no JS, no scrollspy,
  and no active-state hook. Section `id`s on the page are the anchor targets.

  ## Examples

      <.enterprise_anchor_nav links={[{"Teams", "#teams"}, {"Security", "#security"}]} />
  """
  attr :links, :list, required: true, doc: "list of {label, anchor} tuples"
  attr :class, :string, default: nil

  def enterprise_anchor_nav(assigns) do
    ~H"""
    <nav
      aria-label="Enterprise sections"
      class={["border-y border-base-300 bg-base-100", @class]}
    >
      <div class="ds-container flex flex-wrap gap-x-6 gap-y-2 py-4">
        <a
          :for={{label, anchor} <- @links}
          href={anchor}
          class="font-sans text-sm font-semibold text-base-content/70 hover:text-primary"
        >
          {label}
        </a>
      </div>
    </nav>
    """
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/components/marketing_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/components/marketing.ex test/perfect_paper_web/components/marketing_test.exs
git commit -m "feat(marketing): security_card + enterprise_anchor_nav components"
```

---

## Task 4: Enterprise hub page (`/enterprise`)

**Files:**
- Modify: `lib/perfect_paper_web/router.ex`
- Modify: `lib/perfect_paper_web/controllers/page_controller.ex`
- Modify: `lib/perfect_paper_web/controllers/page_html.ex` (add `enterprise_areas/0`)
- Create: `lib/perfect_paper_web/controllers/page_html/enterprise.html.heex`
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/perfect_paper_web/controllers/page_controller_test.exs`:

```elixir
  describe "GET /enterprise" do
    test "renders the hub: security block, anchored sections, and contact CTA", %{conn: conn} do
      body = conn |> get(~p"/enterprise") |> html_response(200)

      assert body =~ "Privacy, by design"

      # Security block: three cards, deep-linking to the security page + compliance anchor.
      assert body =~ "Your content stays yours"
      assert body =~ "Never used to train AI"
      assert body =~ ~s(href="/enterprise/security")
      assert body =~ ~s(href="#compliance")

      # All six anchored area sections render.
      for id <- ~w(security teams access developers compliance support) do
        assert body =~ ~s(id="#{id}")
      end

      # Grounded capability copy.
      assert body =~ "single sign-on" or body =~ "Single sign-on"
      assert body =~ "Webhooks" or body =~ "webhooks"

      # Compliance is honest: pursuing, not held.
      assert body =~ "Pursuing"
      refute body =~ "SOC 2 certified"
      refute body =~ "ISO 27001 certified"

      # Contact-sales CTA.
      assert body =~ "Contact sales"
      assert body =~ ~s(href="/contact")
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: FAIL (no `/enterprise` route).

- [ ] **Step 3: Add the route**

In `lib/perfect_paper_web/router.ex`, in the public `scope "/", PerfectPaperWeb do` block, after the `get "/testimonials", ...` line:

```elixir
    get "/enterprise", PageController, :enterprise
    get "/enterprise/security", PageController, :enterprise_security
```

- [ ] **Step 4: Add the controller actions**

In `lib/perfect_paper_web/controllers/page_controller.ex`, before the final `end`:

```elixir
  def enterprise(conn, _params) do
    render(conn, :enterprise)
  end

  def enterprise_security(conn, _params) do
    render(conn, :enterprise_security)
  end
```

- [ ] **Step 5: Add the area content helper**

In `lib/perfect_paper_web/controllers/page_html.ex`, before the final `end`. Each area maps to a real context, framed honestly. `support` is a sales offering (routes to contact).

```elixir
  @doc false
  # Anchored sections for the /enterprise hub. Each describes shipped capability,
  # framed honestly; `support` is a sales offering, not a built feature.
  def enterprise_areas do
    [
      %{
        id: "security",
        icon: "hero-shield-check",
        title: "Security",
        blurb: "Your manuscripts are encrypted in transit and at rest and are never used to train models.",
        points: [
          "Encryption in transit and at rest",
          "Content never used for model training",
          "Input sanitization on every upload"
        ],
        link_label: "Read the full security page",
        link_href: "/enterprise/security"
      },
      %{
        id: "teams",
        icon: "hero-users",
        title: "Teams & organizations",
        blurb: "Bring your lab or department together with shared organizations, roles, and credits.",
        points: [
          "Organizations with member roles",
          "Groups and per-project access",
          "Invitations and a shared credit pool"
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "access",
        icon: "hero-key",
        title: "Access & identity",
        blurb: "Sign in the way your institution already does, and control exactly who sees what.",
        points: [
          "Single sign-on (SSO)",
          "Organization-enforced multi-factor authentication",
          "Granular, scoped access grants"
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "developers",
        icon: "hero-code-bracket",
        title: "Developer platform",
        blurb: "Automate reviews and stream events into your own systems.",
        points: [
          "API keys and a REST API",
          "Organization-scoped webhooks, HMAC-signed",
          "Delivery log with replay"
        ],
        link_label: "API docs",
        link_href: "/api/docs"
      },
      %{
        id: "compliance",
        icon: "hero-document-check",
        title: "Compliance & data",
        blurb: "Clear data handling and a compliance roadmap you can share with your IT team.",
        points: [
          "Configurable retention and deletion",
          "Documented subprocessors and data residency",
          "Pursuing SOC 2 and ISO 27001 certification"
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "support",
        icon: "hero-lifebuoy",
        title: "Support & SLAs",
        blurb: "Dedicated support, onboarding help, and service-level agreements are available on enterprise plans.",
        points: [
          "Dedicated support contact",
          "Onboarding and IT help-desk resources",
          "Service-level agreements (SLAs)"
        ],
        link_label: "Talk to sales",
        link_href: "/contact"
      }
    ]
  end
```

- [ ] **Step 6: Create the hub template**

`lib/perfect_paper_web/controllers/page_html/enterprise.html.heex`:
```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <%!-- Hero --%>
  <section class="ds-container py-16 text-center lg:py-24">
    <p class="font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary">
      Privacy, by design
    </p>
    <h1 class="ds-h1 mx-auto mt-3 max-w-3xl">
      Built for teams that take research data seriously
    </h1>
    <p class="mx-auto mt-5 max-w-2xl font-serif text-lg leading-relaxed text-base-content/70">
      PerfectPaper gives labs, departments, and institutions the security, access
      controls, and integrations they need — without getting in the way of the work.
    </p>
  </section>

  <%!-- Security block: three cards --%>
  <section class="ds-container pb-4">
    <div class="grid gap-6 md:grid-cols-3">
      <.security_card
        icon="hero-lock-closed"
        title="Your content stays yours"
        body="We protect your manuscripts with strong access controls and encrypted storage, in transit and at rest."
        link_label="Privacy policy"
        link_href={~p"/privacy"}
      />
      <.security_card
        icon="hero-no-symbol"
        title="Never used to train AI"
        body="Your papers are yours. Nothing you upload is ever used as training data."
        link_label="How we handle your data"
        link_href={~p"/enterprise/security"}
      />
      <.security_card
        icon="hero-document-check"
        title="A compliance roadmap"
        body="We're pursuing SOC 2 and ISO 27001. Our data handling and subprocessors are documented for your IT team."
        link_label="See compliance"
        link_href="#compliance"
      />
    </div>
  </section>

  <%!-- In-page anchor nav --%>
  <.enterprise_anchor_nav
    class="mt-12 lg:mt-16"
    links={[
      {"Security", "#security"},
      {"Teams", "#teams"},
      {"Access", "#access"},
      {"Developers", "#developers"},
      {"Compliance", "#compliance"},
      {"Support", "#support"}
    ]}
  />

  <%!-- Anchored area sections --%>
  <section
    :for={area <- enterprise_areas()}
    id={area.id}
    class="ds-container scroll-mt-24 border-b border-base-300 py-14 lg:py-20"
  >
    <div class="grid gap-8 lg:grid-cols-[0.9fr_1.1fr]">
      <div>
        <span class="grid size-11 place-items-center rounded-xl bg-primary/10 text-primary">
          <.icon name={area.icon} class="size-5" />
        </span>
        <h2 class="ds-h2 mt-4">{area.title}</h2>
        <p class="mt-3 max-w-md font-serif text-base-content/70">{area.blurb}</p>
        <a
          :if={area.link_label && area.link_href}
          href={area.link_href}
          class="link link-primary mt-4 inline-block font-sans text-sm font-semibold"
        >
          {area.link_label}
        </a>
      </div>
      <ul class="space-y-3 self-center">
        <li :for={point <- area.points} class="flex items-start gap-2.5 font-serif text-base-content/80">
          <.icon name="hero-check" class="mt-1 size-4 shrink-0 text-success" />
          {point}
        </li>
      </ul>
    </div>
  </section>

  <.cta_banner
    heading="Talk to us about your team."
    subcopy="Tell us about your lab, department, or institution and we'll help you get set up — including security review, onboarding, and SLAs."
    cta_label="Contact sales"
    cta_href={~p"/contact"}
  />
</Layouts.app>
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS.

> If the `developers` icon `hero-code-bracket` is not present in the heroicons set bundled here, the page will raise at render. If the test fails with an icon error, substitute `hero-command-line` in `enterprise_areas/0`. Verify available names with: `grep -rl "code-bracket\|command-line" deps/heroicons/optimized/24/outline 2>/dev/null | head` (or check `assets/vendor/heroicons`).

- [ ] **Step 8: Commit**

```bash
git add lib/perfect_paper_web/router.ex lib/perfect_paper_web/controllers/page_controller.ex lib/perfect_paper_web/controllers/page_html.ex lib/perfect_paper_web/controllers/page_html/enterprise.html.heex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(marketing): enterprise hub at /enterprise with anchored area sections"
```

---

## Task 5: Dedicated security page (`/enterprise/security`)

**Files:**
- Modify: `lib/perfect_paper_web/controllers/page_html.ex` (add `enterprise_security_details/0`)
- Create: `lib/perfect_paper_web/controllers/page_html/enterprise_security.html.heex`
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs`

(Route + controller action were added in Task 4.)

- [ ] **Step 1: Write the failing test**

Add to `test/perfect_paper_web/controllers/page_controller_test.exs`:

```elixir
  describe "GET /enterprise/security" do
    test "renders the in-depth security page with a back-link", %{conn: conn} do
      body = conn |> get(~p"/enterprise/security") |> html_response(200)

      assert body =~ "Security at PerfectPaper"
      assert body =~ "Encryption"
      assert body =~ "Never used for training"
      assert body =~ "Input sanitization"
      assert body =~ "Retention and deletion"

      # Honest compliance wording, not a held certification.
      assert body =~ "Pursuing"
      refute body =~ "SOC 2 certified"

      # Back to the hub.
      assert body =~ ~s(href="/enterprise")
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: FAIL (no `enterprise_security` template).

- [ ] **Step 3: Add the detail content helper**

In `lib/perfect_paper_web/controllers/page_html.ex`, before the final `end`:

```elixir
  @doc false
  # In-depth sections for the /enterprise/security page.
  def enterprise_security_details do
    [
      %{
        title: "Encryption",
        body:
          "Your manuscripts are encrypted in transit (TLS) and at rest. Access is controlled and scoped so only you and the collaborators you choose can read a review."
      },
      %{
        title: "Never used for training",
        body:
          "Your papers are yours. Nothing you upload is ever used as training data, and your content is not shared with third parties for that purpose."
      },
      %{
        title: "Input sanitization",
        body:
          "Uploaded text is run through Unicode sanitization before processing, removing hidden and malformed characters that could otherwise interfere with a review."
      },
      %{
        title: "Retention and deletion",
        body:
          "We keep your documents only as long as needed to produce your review. You can delete a review and its source document at any time."
      },
      %{
        title: "Compliance",
        body:
          "Pursuing SOC 2 and ISO 27001 certification. Our data handling, subprocessors, and security posture are documented and available for your IT and procurement teams."
      }
    ]
  end
```

- [ ] **Step 4: Create the template**

`lib/perfect_paper_web/controllers/page_html/enterprise_security.html.heex`:
```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <section class="ds-container py-16 lg:py-24">
    <a href={~p"/enterprise"} class="link font-sans text-sm text-base-content/60 hover:text-base-content">
      ← Enterprise
    </a>

    <div class="mt-6 max-w-2xl">
      <p class="font-sans text-[11px] font-bold uppercase tracking-[0.16em] text-primary">
        Privacy, by design
      </p>
      <h1 class="ds-h1 mt-3">Security at PerfectPaper</h1>
      <p class="mt-5 font-serif text-lg leading-relaxed text-base-content/70">
        How we keep your research private and secure — from upload to deletion.
      </p>
    </div>

    <div class="mt-12 max-w-3xl space-y-10">
      <div :for={section <- enterprise_security_details()}>
        <h2 class="ds-h3 font-display font-semibold">{section.title}</h2>
        <p class="mt-2 font-serif leading-relaxed text-base-content/75">{section.body}</p>
      </div>
    </div>
  </section>

  <.cta_banner
    heading="Questions about security?"
    subcopy="We're happy to walk your IT or procurement team through our data handling and compliance roadmap."
    cta_label="Contact sales"
    cta_href={~p"/contact"}
  />
</Layouts.app>
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/controllers/page_html.ex lib/perfect_paper_web/controllers/page_html/enterprise_security.html.heex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(marketing): in-depth /enterprise/security page"
```

---

## Task 6: Wire navigation and footer links

**Files:**
- Modify: `lib/perfect_paper_web/components/layouts.ex`
- Test: `test/perfect_paper_web/controllers/page_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/perfect_paper_web/controllers/page_controller_test.exs`:

```elixir
  test "the site chrome links to enterprise and testimonials", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ ~s(href="/enterprise")
    assert body =~ ~s(href="/testimonials")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: FAIL (links not yet present).

- [ ] **Step 3: Add the header nav link**

In `lib/perfect_paper_web/components/layouts.ex`, in the header `<nav>` (the `ml-10 hidden ... md:flex` block), add an Enterprise link after the Examples `<.link>` and before the FAQ anchor:

```heex
          <.link
            navigate={~p"/enterprise"}
            class="font-sans text-sm text-base-content/75 hover:text-base-content"
          >
            Enterprise
          </.link>
```

- [ ] **Step 4: Add footer links**

In `lib/perfect_paper_web/components/layouts.ex` `site_footer/1`, update the "Company" `footer_column` to include Enterprise and Testimonials, and point the "Legal" column's Security link at the new page. Replace the Company column links list with:

```heex
          links={[
            {"Enterprise", ~p"/enterprise"},
            {"Testimonials", ~p"/testimonials"},
            {"Contact", ~p"/contact"},
            {"Trust & privacy", ~p"/#trust"}
          ]}
```

And in the "Legal" column, change the `{"Security", ~p"/#trust"}` tuple to:

```heex
            {"Security", ~p"/enterprise/security"},
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/perfect_paper_web/controllers/page_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/perfect_paper_web/components/layouts.ex test/perfect_paper_web/controllers/page_controller_test.exs
git commit -m "feat(marketing): link enterprise + testimonials from nav and footer"
```

---

## Task 7: Pre-merge verification and merge

- [ ] **Step 1: Run the full page controller + marketing tests**

Run:
```bash
mix test test/perfect_paper_web/controllers/page_controller_test.exs test/perfect_paper_web/components/marketing_test.exs
```
Expected: all PASS.

- [ ] **Step 2: Run `mix precommit`**

Run: `mix precommit`
Expected: compile (warnings-as-errors) clean, format clean, full suite green. Fix anything red — broken tests are yours to fix, no exceptions.

> If `mix format` rewrites any new file, re-stage and amend the last commit or add a `style: format` commit before merging.

- [ ] **Step 3: Merge back to `main`**

```bash
git checkout main && git merge --no-ff feat/home-social-proof-enterprise -m "feat: home social proof + testimonials + enterprise hub/security"
```

- [ ] **Step 4: Report**

Report exactly: "committed and merged back to main with no issues" (only if true).

---

## Self-review notes (already reconciled)

- **Spec coverage:** logo band (Task 1), testimonials page (Task 2), enterprise hub with all six anchored areas + honest compliance (Task 4), dedicated security page (Task 5), nav/footer wiring (Task 6). Components `institution_logos`, `testimonial_card`, `security_card`, `enterprise_anchor_nav` (Tasks 1–3).
- **DRY decision:** existing `trusted_by_section` (text-only, rejected) and `testimonial_grid` (initials, `max-w-6xl` gutter) are intentionally not reused; new components match the home-page `ds-container`/photo-placeholder requirements. Documented in Task 2.
- **Dead-view nav:** `enterprise_anchor_nav` is plain `<a href="#...">` with no `phx-hook` (test-asserted in Task 3) — resolves the LiveView-hook-vs-dead-view contradiction.
- **No reduced-motion handling:** only a `hover:opacity` crossfade is used (logos), which is not the motion `prefers-reduced-motion` governs.
- **"Trusted by" gotcha:** the hero already renders "Trusted by …", so the band test asserts the affiliation-honest heading + institution `alt`s rather than refuting "Trusted by" globally.
- **Icon-name risk:** Task 4 Step 7 has a fallback if `hero-code-bracket` isn't bundled.
