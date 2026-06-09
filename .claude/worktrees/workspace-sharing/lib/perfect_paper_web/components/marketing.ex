defmodule PerfectPaperWeb.Marketing do
  @moduledoc """
  Brand-styled marketing landing components for the PerfectPaper home page.

  These are presentational function components built on daisyUI semantic classes
  and the active `paper` theme tokens — colors, radius, and borders resolve from
  `data-theme`, so the same markup re-skins for free. Long-form copy uses the
  serif faces (`font-display` for headlines, `font-serif` for reading); controls
  and labels use `font-sans` (Outfit).

  The hero's right column is an animated, five-step product demo (Submit →
  Review → Feedback → Discuss → Resolve). The home page is a server-rendered
  dead view, so the animation is driven by a plain DOM module
  (`assets/js/hero_demo.js`, initialised on `DOMContentLoaded` like
  `legal_toc.js`) rather than a LiveView hook. The module targets the
  `#hero-demo` stage by id and cycles its `data-step` attribute (0..4); the
  per-step markup is gated with `data-step`-scoped CSS and keyframe animations
  in `app.css`. No inline `<script>`.
  """
  use Phoenix.Component
  use Gettext, backend: PerfectPaperWeb.Gettext

  import PerfectPaperWeb.CoreComponents, only: [icon: 1]

  @doc """
  The landing hero: a copy column (eyebrow, Fraunces headline, Newsreader
  subcopy, primary + outline CTAs, and a "trusted by" row) beside the animated
  product demo window.

  ## Examples

      <.hero />

      <.hero
        eyebrow="Peer review, reimagined"
        primary_cta_label="Get your review"
        primary_cta_href={~p"/users/register"}
        secondary_cta_label="See a sample"
        secondary_cta_href="#sample"
      />
  """
  attr :eyebrow, :string, default: nil
  attr :primary_cta_label, :string, default: nil
  attr :primary_cta_href, :string, default: "#"
  attr :secondary_cta_label, :string, default: nil
  attr :secondary_cta_href, :string, default: "#"
  attr :trusted_by, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def hero(assigns) do
    assigns =
      assigns
      |> Map.update!(:eyebrow, fn v -> v || gettext("Peer review, reimagined") end)
      |> Map.update!(:primary_cta_label, fn v -> v || gettext("Get your review") end)
      |> Map.update!(:secondary_cta_label, fn v -> v || gettext("See a sample") end)
      |> Map.update!(:trusted_by, fn v ->
        v || gettext("Trusted by researchers at 40+ institutions")
      end)

    ~H"""
    <section class={["relative overflow-hidden", @class]} {@rest}>
      <div class="ds-container pt-14 pb-16 lg:pt-20">
        <div class="flex flex-wrap items-center gap-y-10">
          <%!-- Left: copy --%>
          <div class="w-full lg:w-[42%] lg:pe-8 relative z-10 flex flex-col gap-6">
            <p class="pp-reveal pp-reveal-1 font-sans inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.16em] text-primary">
              <span class="inline-block size-[7px] rounded-full bg-accent"></span>
              {@eyebrow}
            </p>

            <h1 class="pp-reveal pp-reveal-2 font-display font-semibold tracking-[-0.025em] leading-[1.05] text-[clamp(2.1rem,3.4vw,3.4rem)]">
              {gettext("Expert feedback on")}<br />{gettext("your manuscript,")}<br />
              <span class="text-primary">{gettext("before you submit.")}</span>
            </h1>

            <p class="pp-reveal pp-reveal-3 font-serif text-[1.075rem] leading-relaxed max-w-[30rem] text-base-content/70">
              {gettext(
                "PerfectPaper reads your full paper the way a thoughtful reviewer would — then returns structured, sourced feedback you can act on. Discuss any comment, revise with confidence, and walk into submission ready."
              )}
            </p>

            <div class="pp-reveal pp-reveal-4 flex flex-wrap items-center gap-3 pt-1">
              <a href={@primary_cta_href} class="btn btn-primary btn-lg font-sans font-semibold px-8">
                {@primary_cta_label}
              </a>
              <a
                href={@secondary_cta_href}
                class="btn btn-outline btn-lg hidden sm:inline-flex font-sans font-semibold px-7"
              >
                {@secondary_cta_label}
              </a>
            </div>

            <div class="pp-reveal pp-reveal-5 flex items-center gap-2 pt-1 font-sans text-sm text-base-content/50">
              <span class="flex">
                <span class="size-[22px] rounded-full bg-primary border-2 border-base-100"></span>
                <span class="size-[22px] rounded-full bg-secondary border-2 border-base-100 -ml-[7px]">
                </span>
                <span class="size-[22px] rounded-full bg-accent border-2 border-base-100 -ml-[7px]">
                </span>
              </span>
              {@trusted_by}
            </div>
          </div>

          <%!-- Right: animated demo (stacks below the copy on small screens) --%>
          <div class="w-full lg:w-[58%] relative">
            <div class="absolute -inset-x-[4%] -top-[8%] h-[70%] z-0 blur-3xl pointer-events-none
                     bg-[radial-gradient(60%_80%_at_70%_20%,var(--color-primary),transparent_70%)] opacity-20">
            </div>

            <div
              id="hero-demo"
              data-step="0"
              class="pp-stage relative z-[1]"
            >
              <%!-- Decorative product mockup: the real heading/CTAs live in the
                    sibling column, so hide the demo's faux content + icons from
                    assistive tech (the interactive step rail below stays exposed). --%>
              <div
                aria-hidden="true"
                class="rounded-[14px] overflow-hidden bg-base-100 border border-base-300 shadow-[0_30px_60px_-25px_rgba(0,0,0,0.38)]"
              >
                <%!-- title bar --%>
                <div class="flex items-center gap-2.5 px-3.5 py-2.5 bg-base-200/70 border-b border-base-300">
                  <span class="relative grid place-items-center size-[22px] rounded-md bg-primary text-primary-content font-display font-semibold text-sm">
                    P<span class="absolute size-[3px] rounded-full bg-accent right-[3px] bottom-[4px]"></span>
                  </span>
                  <span class="font-display font-semibold text-sm tracking-[-0.01em]">
                    Perfect<span class="text-primary">Paper</span><span class="text-accent">.</span>
                  </span>
                  <span class="hidden sm:block font-sans text-[11.5px] text-base-content/55 truncate max-w-[360px]">
                    Rural–Urban Divides and Cultural Dynamics: HPV &amp; COVID-19 Vaccine Hesitancy…
                  </span>
                  <span class="ml-auto font-sans text-[10.5px] text-base-content/50 border border-base-300 rounded-md px-2.5 py-[3px]">
                    {gettext("Sharing")}
                  </span>
                </div>

                <%!-- sub bar --%>
                <div class="grid grid-cols-2">
                  <div class="px-4 py-2 font-sans text-[10px] tracking-[0.16em] font-semibold text-base-content/45 border-b border-r border-base-300">
                    {gettext("DOCUMENT")}
                  </div>
                  <div class="px-4 py-2 font-sans text-[10px] tracking-[0.16em] font-semibold text-base-content/45 border-b border-base-300">
                    {gettext("FEEDBACK")}
                  </div>
                </div>

                <%!-- body --%>
                <div class="grid grid-cols-2 h-[452px] relative">
                  <%!-- DOCUMENT pane --%>
                  <div class="relative overflow-hidden border-r border-base-300 bg-base-100">
                    <%!-- step 0: upload (no dashed dropzone — the paper only
                          appears once the file finishes uploading) --%>
                    <div class="pp-only pp-s0 absolute inset-0 grid place-items-center px-7">
                      <div class="w-full max-w-[232px] rounded-2xl border border-base-300 bg-base-200/40 px-6 py-7 text-center">
                        <div class="grid place-items-center size-11 mx-auto rounded-xl bg-primary/10 text-primary">
                          <svg
                            width="22"
                            height="22"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="1.7"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          >
                            <path d="M12 16V4m0 0l-4 4m4-4l4 4" />
                            <path d="M4 16v2a2 2 0 002 2h12a2 2 0 002-2v-2" />
                          </svg>
                        </div>
                        <div class="mt-3 font-sans text-xs text-base-content/55">
                          {gettext("Add your manuscript")}
                        </div>
                        <div class="pp-up-card mt-4 flex items-center gap-2.5 rounded-[10px] border border-base-300 bg-base-100 p-2.5 text-left shadow-sm">
                          <span class="grid place-items-center size-8 shrink-0 rounded-md bg-primary/10 font-sans text-[7.5px] font-bold tracking-[0.08em] text-primary">
                            DOCX
                          </span>
                          <span class="min-w-0 flex-1">
                            <span class="block truncate font-sans text-[10.5px] text-base-content/75">
                              {gettext("manuscript.docx")}
                            </span>
                            <span class="mt-1 block h-1 overflow-hidden rounded-full bg-base-300">
                              <i class="pp-up-bar block h-full rounded-full bg-primary"></i>
                            </span>
                          </span>
                        </div>
                        <div class="pp-up-done mt-3 inline-flex items-center gap-1.5 font-sans text-[11px] font-semibold text-success">
                          <svg
                            width="12"
                            height="12"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          >
                            <path d="M5 12l5 5 9-11" />
                          </svg>
                          {gettext("Uploaded")}
                        </div>
                      </div>
                    </div>

                    <%!-- persistent manuscript (steps 1–4; hidden during upload) --%>
                    <div class="pp-doc-paper pp-only pp-s1 pp-s2 pp-s3 pp-s4 absolute inset-0 overflow-hidden">
                      <div class="px-6 py-4">
                        <div class="font-sans text-[8.5px] tracking-[0.18em] font-bold uppercase text-base-content/40">
                          SSM — Population Health
                        </div>
                        <div class="font-display font-semibold text-[16px] leading-tight mt-1.5 mb-3 tracking-[-0.01em] max-w-[92%]">
                          Rural–Urban Divides and Cultural Dynamics in Vaccine Hesitancy
                        </div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-full"></div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[92%]"></div>

                        <%!-- §3.1 — comment #2 (secondary highlight) --%>
                        <div class="h-[9px] rounded bg-base-content/25 mt-4 mb-2 w-[40%]"></div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[96%]"></div>
                        <div class="pp-hl pp-hl-2 -ml-2 rounded-sm py-1 pl-2">
                          <div class="h-[7px] rounded bg-base-content/20 w-[99%]"></div>
                          <div class="h-[7px] rounded bg-base-content/20 mt-1.5 w-[58%]"></div>
                        </div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[88%]"></div>

                        <%!-- §3.2 — comment #1 (primary highlight) --%>
                        <div class="h-[9px] rounded bg-base-content/25 mt-4 mb-2 w-[44%]"></div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[94%]"></div>
                        <div class="pp-hl pp-hl-1 -ml-2 rounded-sm py-1 pl-2">
                          <div class="h-[7px] rounded bg-base-content/20 w-[99%]"></div>
                          <div class="h-[7px] rounded bg-base-content/20 mt-1.5 w-[66%]"></div>
                        </div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[84%]"></div>

                        <%!-- Table 4 / §4.1 — comment #3 (accent highlight) --%>
                        <div class="h-[9px] rounded bg-base-content/25 mt-4 mb-2 w-[34%]"></div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[90%]"></div>
                        <div class="pp-hl pp-hl-3 -ml-2 rounded-sm py-1 pl-2">
                          <div class="h-[7px] rounded bg-base-content/20 w-[78%]"></div>
                        </div>
                        <div class="h-[7px] rounded bg-base-content/10 my-1.5 w-[70%]"></div>
                      </div>

                      <%!-- scan + status (step 1 only; no highlights yet) --%>
                      <div class="pp-only pp-s1 pp-doc-scan absolute left-0 right-0 h-16 z-[4] pointer-events-none
                                  bg-gradient-to-b from-transparent via-primary/20 to-transparent border-t border-primary/55">
                      </div>
                      <div class="pp-only pp-s1 absolute left-[18px] bottom-4 z-[5] flex items-center gap-2
                                  bg-base-100 border border-base-300 rounded-full px-3 py-1.5 font-sans text-[11px] shadow-md">
                        <span class="loading loading-spinner loading-xs text-primary"></span>
                        {gettext("Reading Section 3.2 — methods")}
                      </div>
                    </div>
                  </div>

                  <%!-- FEEDBACK pane --%>
                  <div class="relative overflow-hidden bg-base-200/55">
                    <%!-- step 0 placeholder --%>
                    <div class="pp-only pp-s0 h-full flex flex-col items-center justify-center gap-2 text-base-content/40">
                      <svg
                        width="26"
                        height="26"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="1.4"
                      >
                        <path d="M4 5h16M4 10h16M4 15h10" stroke-linecap="round" />
                      </svg>
                      <span class="font-sans text-[11px]">{gettext("Awaiting your manuscript")}</span>
                    </div>

                    <%!-- step 1 skeleton --%>
                    <div class="pp-only pp-s1 p-[18px] flex flex-col gap-3 h-full box-border">
                      <div class="skeleton h-[11px] w-[90px]"></div>
                      <div class="rounded-[10px] border border-base-300 bg-base-100 p-3.5">
                        <div class="skeleton h-[11px] w-[60%]"></div>
                        <div class="skeleton h-2 w-full mt-2.5"></div>
                        <div class="skeleton h-2 w-[92%] mt-1.5"></div>
                      </div>
                      <div class="rounded-[10px] border border-base-300 bg-base-100 p-3.5">
                        <div class="skeleton h-[11px] w-[50%]"></div>
                        <div class="skeleton h-2 w-full mt-2.5"></div>
                        <div class="skeleton h-2 w-[80%] mt-1.5"></div>
                      </div>
                    </div>

                    <%!-- step 2 feedback: overall summary lands first, then the
                          detailed cards reveal one-by-one in sync with the
                          document highlights --%>
                    <div class="pp-only pp-s2 box-border flex h-full flex-col gap-2.5 overflow-hidden p-[18px]">
                      <div class="pp-fb-overall rounded-[10px] border border-base-300 bg-base-100 p-3">
                        <div class="flex items-center gap-2">
                          <svg
                            class="size-3.5 text-secondary"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="1.7"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          >
                            <path d="M4 4h16v12H7l-3 3V4z" />
                          </svg>
                          <span class="font-display text-[12.5px] font-semibold">
                            {gettext("Overall feedback")}
                          </span>
                          <span class="rounded bg-secondary/15 px-1.5 py-px font-sans text-[9px] font-semibold text-secondary">
                            {gettext("Summary")}
                          </span>
                          <span class="ml-auto rounded-full bg-primary px-2 py-px font-sans text-[10px] font-bold text-primary-content">
                            3
                          </span>
                        </div>
                        <p class="mt-1.5 font-serif text-[11px] leading-relaxed text-base-content/70">
                          {gettext(
                            "Three issues stand between this draft and a clean submission — the causal model in §3.2, the scale construction in §3.1, and a reconciliation error in Table 4."
                          )}
                        </p>
                      </div>

                      <div class="px-0.5 font-sans text-[9px] font-semibold uppercase tracking-[0.16em] text-base-content/45">
                        {gettext("Detailed feedback")}
                      </div>

                      <div class="pp-fb-1 rounded-[10px] border border-base-300 bg-base-100 p-3">
                        <div class="font-display text-[12px] font-semibold leading-snug">
                          <span class="mr-1 font-bold text-primary">#1</span>{gettext(
                            "Causal adjustment underspecified in §3.2"
                          )}
                        </div>
                        <div class="mt-1.5 border-l-2 border-primary/70 pl-2.5 font-serif text-[10.5px] italic leading-relaxed text-base-content/70">
                          {gettext(
                            "As shown in Figure 2, directed acyclic graphs encoded a priori knowledge for estimating total effects…"
                          )}
                        </div>
                        <div class="mt-2 flex items-center gap-2 border-t border-base-200 pt-2 font-sans text-[9.5px] font-semibold text-base-content/45">
                          <span class="inline-flex items-center gap-1 text-primary/80">
                            <svg
                              class="size-3"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="1.8"
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            >
                              <path d="M21 12a8 8 0 01-11.5 7.2L4 20l1-4.8A8 8 0 1121 12z" />
                            </svg>
                            {gettext("Discussion")}
                          </span>
                          <span class="ml-auto">{gettext("← Show in the doc")}</span>
                        </div>
                      </div>

                      <div class="pp-fb-2 rounded-[10px] border border-base-300 bg-base-100 p-3">
                        <div class="font-display text-[12px] font-semibold leading-snug">
                          <span class="mr-1 font-bold text-secondary">#2</span>{gettext(
                            "Construction of the hesitancy scales"
                          )}
                        </div>
                        <div class="mt-1.5 border-l-2 border-secondary/70 pl-2.5 font-serif text-[10.5px] leading-relaxed text-base-content/70">
                          {gettext(
                            "The three factor-derived scales in §3.1 carry your conclusions — give readers the psychometric evidence."
                          )}
                        </div>
                        <div class="mt-2 flex items-center gap-2 border-t border-base-200 pt-2 font-sans text-[9.5px] font-semibold text-base-content/45">
                          <span class="inline-flex items-center gap-1">
                            <svg
                              class="size-3"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="1.8"
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            >
                              <path d="M21 12a8 8 0 01-11.5 7.2L4 20l1-4.8A8 8 0 1121 12z" />
                            </svg>
                            {gettext("Discussion")}
                          </span>
                          <span class="ml-auto">{gettext("← Show in the doc")}</span>
                        </div>
                      </div>

                      <div class="pp-fb-3 rounded-[10px] border border-base-300 bg-base-100 p-3">
                        <div class="font-display text-[12px] font-semibold leading-snug">
                          <span class="mr-1 font-bold text-accent">#3</span>{gettext(
                            "Incorrect sample sizes in Table 4"
                          )}
                        </div>
                        <div class="mt-1.5 border-l-2 border-accent/70 pl-2.5 font-serif text-[10.5px] leading-relaxed text-base-content/70">
                          {gettext(
                            "The Hispanic young-adult subgroup counts don't reconcile with the totals in §4.1."
                          )}
                        </div>
                        <div class="mt-2 flex items-center gap-2 border-t border-base-200 pt-2 font-sans text-[9.5px] font-semibold text-base-content/45">
                          <span class="inline-flex items-center gap-1">
                            <svg
                              class="size-3"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="1.8"
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            >
                              <path d="M21 12a8 8 0 01-11.5 7.2L4 20l1-4.8A8 8 0 1121 12z" />
                            </svg>
                            {gettext("Discussion")}
                          </span>
                          <span class="ml-auto">{gettext("← Show in the doc")}</span>
                        </div>
                      </div>
                    </div>

                    <%!-- step 4 resolve: revisions land, then a polish (re-run)
                          pass confirms nothing new, then export --%>
                    <div class="pp-only pp-s4 box-border flex h-full flex-col gap-2.5 overflow-hidden p-[18px]">
                      <div class="flex items-center gap-2">
                        <svg
                          class="size-4 text-success"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.7"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M9 12l2 2 4-4" />
                          <circle cx="12" cy="12" r="9" />
                        </svg>
                        <span class="font-display text-[13px] font-semibold">
                          {gettext("Revision complete")}
                        </span>
                        <span class="ml-auto rounded-full bg-success px-2 py-px font-sans text-[10px] font-bold text-success-content">
                          3 / 3
                        </span>
                      </div>

                      <div class="flex items-center gap-2 rounded-[10px] border border-success/40 bg-success/5 px-3 py-2 font-sans text-[11px]">
                        <svg
                          class="size-3.5 shrink-0 text-success"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="3"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M5 12l5 5 9-11" />
                        </svg>
                        <span class="font-bold text-primary">#1</span>
                        <span class="text-base-content/70">{gettext("Causal adjustment")}</span>
                        <span class="ml-auto font-semibold text-success">{gettext("Addressed")}</span>
                      </div>
                      <div class="flex items-center gap-2 rounded-[10px] border border-success/40 bg-success/5 px-3 py-2 font-sans text-[11px]">
                        <svg
                          class="size-3.5 shrink-0 text-success"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="3"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M5 12l5 5 9-11" />
                        </svg>
                        <span class="font-bold text-secondary">#2</span>
                        <span class="text-base-content/70">{gettext("Hesitancy scales")}</span>
                        <span class="ml-auto font-semibold text-success">{gettext("Addressed")}</span>
                      </div>
                      <div class="flex items-center gap-2 rounded-[10px] border border-success/40 bg-success/5 px-3 py-2 font-sans text-[11px]">
                        <svg
                          class="size-3.5 shrink-0 text-success"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="3"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M5 12l5 5 9-11" />
                        </svg>
                        <span class="font-bold text-accent">#3</span>
                        <span class="text-base-content/70">{gettext("Sample sizes")}</span>
                        <span class="ml-auto font-semibold text-success">{gettext("Addressed")}</span>
                      </div>

                      <div class="rounded-[10px] border border-base-300 bg-base-100 p-3">
                        <div class="relative h-[18px]">
                          <div class="pp-polish-a absolute inset-0 flex items-center gap-2 font-sans text-[11px] font-semibold text-base-content/70">
                            <span class="loading loading-spinner loading-xs text-primary"></span>
                            {gettext("Re-running PerfectPaper review…")}
                          </div>
                          <div class="pp-polish-b absolute inset-0 flex items-center gap-2 font-sans text-[11px] font-semibold text-base-content/80">
                            <svg
                              class="size-3.5 text-success"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="3"
                              stroke-linecap="round"
                              stroke-linejoin="round"
                            >
                              <path d="M5 12l5 5 9-11" />
                            </svg>
                            {gettext("Polish pass — no new issues")}
                          </div>
                        </div>
                      </div>

                      <div class="mt-auto flex items-center justify-center gap-2 rounded-[9px] bg-primary py-2.5 font-sans text-xs font-semibold text-primary-content">
                        <svg
                          width="14"
                          height="14"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.8"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        >
                          <path d="M12 4v12m0 0l-4-4m4 4l4-4" />
                          <path d="M4 18h16" />
                        </svg>
                        {gettext("Export revised manuscript")}
                      </div>
                    </div>

                    <%!-- step 3: the #1 card's Discussion expands — a real
                          collaborator comments, the bot is invited in, it
                          replies (the typing dots are replaced in place by the
                          answer), then the conversation continues --%>
                    <div class="pp-only pp-s3 pp-chat absolute inset-0 flex flex-col bg-base-200/40">
                      <div class="flex items-center gap-2 px-4 py-2.5 border-b border-base-300 font-sans font-semibold text-[10.5px] tracking-[0.12em] text-base-content/55">
                        <svg
                          width="13"
                          height="13"
                          viewBox="0 0 24 24"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="1.7"
                        >
                          <path
                            d="M21 12a8 8 0 01-11.5 7.2L4 20l1-4.8A8 8 0 1121 12z"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          />
                        </svg>
                        {gettext("DISCUSSION · #1")}
                      </div>
                      <div class="px-4 pt-3">
                        <div class="rounded-[9px] border border-base-300 border-l-2 border-l-primary/70 bg-base-100 px-3 py-2 font-display text-[11px] font-semibold text-base-content/80">
                          {gettext("Causal adjustment underspecified in §3.2")}
                        </div>
                      </div>
                      <div class="flex flex-1 flex-col gap-3 overflow-hidden px-4 py-3">
                        <div class="pp-d1 flex flex-col gap-1">
                          <span class="font-sans text-[10.5px] font-semibold text-base-content/55">
                            {gettext("Dr. Anya Rao · co-author")}
                          </span>
                          <p class="font-serif text-[11.5px] leading-snug text-base-content/80">
                            {gettext("Can we make the adjustment set explicit before we resubmit?")}
                          </p>
                        </div>
                        <div class="pp-d2 inline-flex items-center gap-1.5 self-start rounded-full border border-base-300 bg-base-100 px-2.5 py-1 font-sans text-[10px] font-semibold text-primary">
                          <svg
                            width="11"
                            height="11"
                            viewBox="0 0 24 24"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="1.8"
                            stroke-linecap="round"
                            stroke-linejoin="round"
                          >
                            <path d="M12 3v3m0 12v3M5 12H2m20 0h-3M6.3 6.3 4 4m16 16-2.3-2.3M6.3 17.7 4 20M20 4l-2.3 2.3" />
                          </svg>
                          {gettext("Asked PerfectPaper")}
                        </div>
                        <div class="pp-d3 flex flex-col gap-1">
                          <span class="font-sans text-[10.5px] font-semibold text-primary">
                            PerfectPaper
                          </span>
                          <div class="relative max-w-[94%] self-start rounded-[13px] rounded-bl-[4px] border border-base-300 bg-base-100 px-3 py-2.5">
                            <span class="pp-d3-dots absolute inset-0 grid place-items-center">
                              <span class="pp-typing inline-flex gap-1">
                                <span class="size-[5px] rounded-full bg-base-content/40"></span>
                                <span class="size-[5px] rounded-full bg-base-content/40"></span>
                                <span class="size-[5px] rounded-full bg-base-content/40"></span>
                              </span>
                            </span>
                            <p class="pp-d3-text font-serif text-[11.5px] leading-snug text-base-content/80">
                              {gettext(
                                "State each backdoor path you're closing and cite the assumption behind every included covariate."
                              )}
                            </p>
                          </div>
                        </div>
                        <div class="pp-d4 flex flex-col gap-1">
                          <span class="font-sans text-[10.5px] font-semibold text-base-content/55">
                            {gettext("You")}
                          </span>
                          <p class="font-serif text-[11.5px] leading-snug text-base-content/80">
                            {gettext("Perfect — adding it to the methods now.")}
                          </p>
                        </div>
                      </div>
                      <div class="m-3 flex items-center gap-2">
                        <div class="flex-1 rounded-[9px] border border-base-300 bg-base-100 px-2.5 py-2 font-sans text-[11px] text-base-content/45">
                          {gettext("Add a comment or criticism…")}
                        </div>
                        <span class="rounded-[8px] bg-primary px-2.5 py-2 font-sans text-[11px] font-semibold text-primary-content">
                          {gettext("Reply")}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <%!-- step rail --%>
              <div class="pp-rail flex items-center mt-5" data-rail>
                <button type="button" class="pp-rail-step flex flex-col gap-1 text-left" data-i="0">
                  <span class="pp-rail-num font-sans font-bold text-[11px] text-base-content/35">
                    01
                  </span>
                  <span class="pp-rail-label font-sans font-semibold text-[11px] sm:text-[12.5px] text-base-content/45 whitespace-nowrap">
                    {gettext("Submit")}
                  </span>
                </button>
                <span class="pp-rail-line flex-1 h-0.5 mx-1.5 sm:mx-3 bg-base-300 relative overflow-hidden">
                  <i class="absolute inset-0 bg-primary origin-left scale-x-0"></i>
                </span>
                <button type="button" class="pp-rail-step flex flex-col gap-1 text-left" data-i="1">
                  <span class="pp-rail-num font-sans font-bold text-[11px] text-base-content/35">
                    02
                  </span>
                  <span class="pp-rail-label font-sans font-semibold text-[11px] sm:text-[12.5px] text-base-content/45 whitespace-nowrap">
                    {gettext("Review")}
                  </span>
                </button>
                <span class="pp-rail-line flex-1 h-0.5 mx-1.5 sm:mx-3 bg-base-300 relative overflow-hidden">
                  <i class="absolute inset-0 bg-primary origin-left scale-x-0"></i>
                </span>
                <button type="button" class="pp-rail-step flex flex-col gap-1 text-left" data-i="2">
                  <span class="pp-rail-num font-sans font-bold text-[11px] text-base-content/35">
                    03
                  </span>
                  <span class="pp-rail-label font-sans font-semibold text-[11px] sm:text-[12.5px] text-base-content/45 whitespace-nowrap">
                    {gettext("Feedback")}
                  </span>
                </button>
                <span class="pp-rail-line flex-1 h-0.5 mx-1.5 sm:mx-3 bg-base-300 relative overflow-hidden">
                  <i class="absolute inset-0 bg-primary origin-left scale-x-0"></i>
                </span>
                <button type="button" class="pp-rail-step flex flex-col gap-1 text-left" data-i="3">
                  <span class="pp-rail-num font-sans font-bold text-[11px] text-base-content/35">
                    04
                  </span>
                  <span class="pp-rail-label font-sans font-semibold text-[11px] sm:text-[12.5px] text-base-content/45 whitespace-nowrap">
                    {gettext("Discuss")}
                  </span>
                </button>
                <span class="pp-rail-line flex-1 h-0.5 mx-1.5 sm:mx-3 bg-base-300 relative overflow-hidden">
                  <i class="absolute inset-0 bg-primary origin-left scale-x-0"></i>
                </span>
                <button type="button" class="pp-rail-step flex flex-col gap-1 text-left" data-i="4">
                  <span class="pp-rail-num font-sans font-bold text-[11px] text-base-content/35">
                    05
                  </span>
                  <span class="pp-rail-label font-sans font-semibold text-[11px] sm:text-[12.5px] text-base-content/45 whitespace-nowrap">
                    {gettext("Resolve")}
                  </span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  A three-card feature section. Pass your own cards via the `features` list, or
  rely on the defaults that describe the PerfectPaper review loop.

  ## Examples

      <.feature_grid />

      <.feature_grid features={[
        %{title: "Full-paper reading", body: "Every section, in context."},
        %{title: "Sourced feedback", body: "Each comment cites the passage."},
        %{title: "Discuss and resolve", body: "Talk through any comment."}
      ]} />
  """
  attr :eyebrow, :string, default: nil
  attr :heading, :string, default: nil

  attr :features, :list, default: nil

  attr :class, :string, default: nil
  attr :rest, :global

  def feature_grid(assigns) do
    assigns =
      assigns
      |> Map.update!(:eyebrow, fn v -> v || gettext("How it works") end)
      |> Map.update!(:heading, fn v -> v || gettext("A reviewer that reads the whole paper") end)
      |> Map.update!(:features, fn v ->
        v ||
          [
            %{
              title: gettext("Full-paper reading"),
              body:
                gettext(
                  "PerfectPaper reads every section in context — methods, claims, and figures together — not a paragraph at a time."
                )
            },
            %{
              title: gettext("Structured, sourced feedback"),
              body:
                gettext(
                  "Each comment quotes the passage it refers to and explains the issue, so you always know exactly what to revise."
                )
            },
            %{
              title: gettext("Discuss, then resolve"),
              body:
                gettext(
                  "Talk through any comment with PerfectPaper, mark it addressed, and export a submission-ready manuscript."
                )
            }
          ]
      end)

    ~H"""
    <section class={["ds-container py-16 lg:py-24", @class]} {@rest}>
      <div class="max-w-2xl mb-10 lg:mb-14">
        <p class="font-sans text-xs font-semibold uppercase tracking-[0.16em] text-primary mb-3">
          {@eyebrow}
        </p>
        <h2 class="font-display font-semibold text-3xl lg:text-4xl tracking-[-0.02em] leading-tight">
          {@heading}
        </h2>
      </div>

      <div class="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
        <div :for={feature <- @features} class="card bg-base-100 border border-base-300">
          <div class="card-body gap-2">
            <h3 class="card-title font-display text-lg">{feature.title}</h3>
            <p class="font-serif text-sm leading-relaxed text-base-content/70">{feature.body}</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  The closing call-to-action band.

  ## Examples

      <.cta_banner />

      <.cta_banner
        heading="Ready when you are."
        cta_label="Start your review"
        cta_href={~p"/users/register"}
      />
  """
  attr :heading, :string, default: nil
  attr :subcopy, :string, default: nil
  attr :cta_label, :string, default: nil
  attr :cta_href, :string, default: "#"
  attr :class, :string, default: nil
  attr :rest, :global

  def cta_banner(assigns) do
    assigns =
      assigns
      |> Map.update!(:heading, fn v -> v || gettext("Walk into submission ready.") end)
      |> Map.update!(:subcopy, fn v ->
        v ||
          gettext(
            "Upload your manuscript and get structured, sourced feedback in minutes — the way a thoughtful reviewer would give it."
          )
      end)
      |> Map.update!(:cta_label, fn v -> v || gettext("Get your review") end)

    ~H"""
    <section class={["ds-container pb-16 lg:pb-24", @class]} {@rest}>
      <div class="rounded-box border border-base-300 bg-base-200 px-6 py-12 sm:px-12 lg:py-16 text-center">
        <h2 class="font-display font-semibold text-3xl lg:text-4xl tracking-[-0.02em] leading-tight max-w-2xl mx-auto">
          {@heading}
        </h2>
        <p class="font-serif text-base lg:text-lg leading-relaxed text-base-content/70 max-w-xl mx-auto mt-4">
          {@subcopy}
        </p>
        <div class="mt-8">
          <a href={@cta_href} class="btn btn-primary btn-lg font-sans font-semibold px-8">
            {@cta_label}
          </a>
        </div>
      </div>
    </section>
    """
  end

  @doc """
  An "affiliation-honest" social-proof band: a row of institution wordmarks shown
  at a uniform height with a unifying grayscale + opacity treatment. These mark
  the institutions that fund/employ the team, not endorsing customers — copy is
  worded accordingly (no "trusted by"/endorsement claim).

  ## Examples

      <.institution_logos />

      <.institution_logos
        heading="Research affiliated with"
        logos={[%{src: "/images/institutions/university-of-utah.svg", alt: "University of Utah"}]}
      />
  """
  attr :eyebrow, :string, default: nil
  attr :heading, :string, default: nil
  attr :logos, :list, default: nil

  attr :class, :string, default: nil
  attr :rest, :global

  def institution_logos(assigns) do
    assigns =
      assigns
      |> Map.update!(:eyebrow, fn v -> v || gettext("Affiliations") end)
      |> Map.update!(:heading, fn v ->
        v || gettext("Built by researchers funded by leading cancer-prevention institutions")
      end)
      |> Map.update!(:logos, fn v ->
        v ||
          [
            %{
              src: "/images/institutions/university-of-utah.svg",
              alt: gettext("University of Utah")
            },
            %{
              src: "/images/institutions/huntsman-cancer-institute.svg",
              alt: gettext("Huntsman Cancer Institute")
            },
            %{
              src: "/images/institutions/national-cancer-institute.svg",
              alt: gettext("National Cancer Institute")
            },
            %{
              src: "/images/institutions/american-cancer-society.svg",
              alt: gettext("American Cancer Society")
            }
          ]
      end)

    ~H"""
    <section
      id="affiliations"
      class={["border-y border-base-300 bg-base-200/40 py-12 lg:py-16", @class]}
      {@rest}
    >
      <div class="ds-container">
        <p class="ds-eyebrow text-center">
          {@eyebrow}
        </p>
        <h2 class="ds-h3 mt-2 mb-8 max-w-2xl mx-auto text-center font-semibold">
          {@heading}
        </h2>
        <ul class="grid grid-cols-2 items-center justify-items-center gap-x-8 gap-y-10 sm:grid-cols-4">
          <li :for={logo <- @logos} class="flex items-center justify-center">
            <img
              src={logo.src}
              alt={logo.alt}
              loading="lazy"
              class="h-8 w-auto object-contain opacity-60 grayscale transition hover:opacity-100 hover:grayscale-0 sm:h-9"
            />
          </li>
        </ul>
      </div>
    </section>
    """
  end

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
  attr :avatar_alt, :string, default: ""
  attr :class, :string, default: nil
  attr :rest, :global

  def testimonial_card(assigns) do
    ~H"""
    <figure class={["card flex flex-col border border-base-300 bg-base-100", @class]} {@rest}>
      <div class="card-body gap-6">
        <blockquote class="flex-1 font-serif text-[1.05rem] italic leading-relaxed text-base-content/85">
          "{@quote}"
        </blockquote>
        <figcaption class="flex items-center gap-3.5 border-t border-base-300 pt-5">
          <div :if={@avatar_src} class="avatar">
            <div class="w-11 rounded-full">
              <img src={@avatar_src} alt={@avatar_alt} loading="lazy" />
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
  attr :rest, :global

  def security_card(assigns) do
    ~H"""
    <div class={["card border border-base-300 bg-base-100", @class]} {@rest}>
      <div class="card-body gap-3">
        <span class="grid size-11 place-items-center rounded-xl bg-primary/10 text-primary">
          <.icon name={@icon} class="size-5" />
        </span>
        <h3 class="card-title font-display text-lg">{@title}</h3>
        <p class="font-serif text-sm leading-relaxed text-base-content/70">{@body}</p>
        <a
          :if={@link_label && @link_href}
          href={@link_href}
          class="link link-primary font-sans text-sm font-semibold"
        >
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
  attr :rest, :global

  def enterprise_anchor_nav(assigns) do
    ~H"""
    <nav
      aria-label={gettext("Enterprise sections")}
      class={["border-y border-base-300 bg-base-100", @class]}
      {@rest}
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

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&String.ends_with?(&1, "."))
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> case do
      [] -> "?"
      parts -> parts |> Enum.join() |> String.upcase()
    end
  end
end
