defmodule PerfectPaperWeb.MarketingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PerfectPaperWeb.Marketing

  describe "hero/1" do
    test "renders the headline, CTAs, trusted-by row, and the demo hook" do
      html = render_component(&hero/1, %{})

      # Headline (Fraunces / font-display)
      assert html =~ "Expert feedback on"
      assert html =~ "before you submit."
      assert html =~ "font-display"

      # Subcopy keeps the brand one-word spelling
      assert html =~ "PerfectPaper reads your full paper"

      # CTAs use daisyUI button classes
      assert html =~ "btn btn-primary"
      assert html =~ "btn btn-outline"
      assert html =~ "Get your review"
      assert html =~ "See a sample"

      # Eyebrow + trusted-by row
      assert html =~ "Peer review, reimagined"
      assert html =~ "Trusted by researchers at 40+ institutions"

      # The animated demo is a server-rendered dead view: the JS module targets
      # the `#hero-demo` stage by id (no LiveView hook, no inline script).
      assert html =~ ~s(id="hero-demo")
      assert html =~ "pp-stage"
      assert html =~ ~s(data-step="0")
      refute html =~ "phx-hook"
      refute html =~ "<script"

      # Step rail labels for the five-step demo
      for label <- ~w(Submit Review Feedback Discuss Resolve) do
        assert html =~ label
      end
    end

    test "keeps the animated demo visible on small screens" do
      html = render_component(&hero/1, %{})

      # Previously the demo column was desktop-only (`hidden lg:block`); it now
      # stacks below the copy on small screens instead of disappearing.
      refute html =~ "hidden lg:block"
      assert html =~ ~s(id="hero-demo")
    end

    test "uses the shared page container so it lines up with every section" do
      html = render_component(&hero/1, %{})

      # .ds-container (mx-auto max-w-6xl px-6 sm:px-8) is the one page width;
      # no bespoke max-w-7xl/6xl literal on the section wrapper.
      assert html =~ "ds-container"
      refute html =~ "max-w-7xl"
      refute html =~ "max-w-6xl"
    end

    test "hides the secondary CTA on phones, keeps the primary visible" do
      html = render_component(&hero/1, %{})

      # "See a sample" is secondary — drop it on phones so the hero leads with
      # a single clear action; it returns from sm up.
      assert html =~ ~s(<a href="#" class="btn btn-outline btn-lg hidden sm:inline-flex)
      # The primary "Get your review" CTA stays visible at every size.
      refute html =~ ~s(btn btn-primary btn-lg hidden)
    end

    test "accepts custom CTA labels and hrefs" do
      html =
        render_component(&hero/1, %{
          primary_cta_label: "Start now",
          primary_cta_href: "/register",
          secondary_cta_label: "View example",
          secondary_cta_href: "/sample"
        })

      assert html =~ "Start now"
      assert html =~ ~s(href="/register")
      assert html =~ "View example"
      assert html =~ ~s(href="/sample")
    end
  end

  describe "feature_grid/1" do
    test "renders three daisyUI cards with default copy" do
      html = render_component(&feature_grid/1, %{})

      assert html =~ "How it works"
      assert html =~ "A reviewer that reads the whole paper"
      assert html =~ "Full-paper reading"
      assert html =~ "Structured, sourced feedback"
      assert html =~ "Discuss, then resolve"

      # daisyUI card markup, one per feature (3)
      assert html =~ "card"
      assert html =~ "card-body"
      assert length(String.split(html, "card-title")) - 1 == 3
    end

    test "renders caller-supplied features" do
      html =
        render_component(&feature_grid/1, %{
          features: [%{title: "Only one", body: "Just this card."}]
        })

      assert html =~ "Only one"
      assert html =~ "Just this card."
    end
  end

  describe "cta_banner/1" do
    test "renders the closing heading, subcopy, and CTA button" do
      html = render_component(&cta_banner/1, %{})

      assert html =~ "Walk into submission ready."
      assert html =~ "Get your review"
      assert html =~ "btn btn-primary"
    end

    test "accepts a custom heading and CTA" do
      html =
        render_component(&cta_banner/1, %{
          heading: "Ready when you are.",
          cta_label: "Start your review",
          cta_href: "/go"
        })

      assert html =~ "Ready when you are."
      assert html =~ "Start your review"
      assert html =~ ~s(href="/go")
    end
  end

  describe "security_card/1" do
    test "renders icon tile, title, body, and optional link" do
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

    test "omits the link when no link_href given" do
      html =
        render_component(&security_card/1, %{
          icon: "hero-lock-closed",
          title: "No link card",
          body: "Body text."
        })

      assert html =~ "No link card"
      refute html =~ "<a "
    end
  end

  describe "enterprise_anchor_nav/1" do
    test "renders plain anchor links with no JS hooks" do
      html =
        render_component(&enterprise_anchor_nav/1, %{
          links: [{"Teams", "#teams"}, {"Developers", "#developers"}]
        })

      assert html =~ ~s(href="#teams")
      assert html =~ ~s(href="#developers")
      assert html =~ "Teams"
      refute html =~ "phx-hook"
    end
  end

  describe "institution_logos/1" do
    test "renders default heading, id, all four institution alts, and list structure" do
      html = render_component(&institution_logos/1, %{})

      assert html =~ "Built by researchers funded by leading cancer-prevention institutions"
      assert html =~ ~s(id="affiliations")

      assert html =~ ~s(alt="University of Utah")
      assert html =~ ~s(alt="Huntsman Cancer Institute")
      assert html =~ ~s(alt="National Cancer Institute")
      assert html =~ ~s(alt="American Cancer Society")

      assert html =~ "<ul"
      assert html =~ "<li"
    end

    test "renders caller-supplied logos and does not render default institution" do
      html =
        render_component(&institution_logos/1, %{
          logos: [%{src: "/x.svg", alt: "Custom Lab"}]
        })

      assert html =~ ~s(alt="Custom Lab")
      assert html =~ ~s(src="/x.svg")
      refute html =~ "University of Utah"
    end
  end

  describe "testimonial_card/1" do
    test "with avatar photo renders quote, attribution, and decorative img" do
      html =
        render_component(&testimonial_card/1, %{
          quote: "Sharp feedback.",
          name: "Jane Avery",
          title: "Professor",
          institution: "State University",
          avatar_src: "/images/avatar-placeholder.svg"
        })

      assert html =~ "Sharp feedback."
      assert html =~ "Jane Avery"
      assert html =~ "Professor"
      assert html =~ "State University"
      assert html =~ ~s(src="/images/avatar-placeholder.svg")
      # avatar img is decorative — alt must be empty string
      assert html =~ ~s(alt="")
    end

    test "without avatar falls back to initials placeholder" do
      html =
        render_component(&testimonial_card/1, %{
          quote: "Great tool.",
          name: "Jane Avery",
          title: "Researcher",
          institution: "MIT"
        })

      assert html =~ "avatar-placeholder"
      assert html =~ "JA"
    end
  end
end
