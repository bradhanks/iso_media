defmodule PerfectPaperWeb.PageControllerTest do
  use PerfectPaperWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "PerfectPaper"
  end

  test "GET / lines every section up on one shared page container", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # Header, footer, and every home section share .ds-container
    # (mx-auto max-w-6xl px-6 sm:px-8), so their left/right edges line up.
    # No bespoke page widths remain.
    assert body =~ "ds-container"
    refute body =~ "max-w-7xl"
    refute body =~ "max-w-6xl"
  end

  test "GET /contact uses the shared page container", %{conn: conn} do
    body = conn |> get(~p"/contact") |> html_response(200)
    assert body =~ "ds-container"
    refute body =~ "max-w-7xl"
  end

  test "GET /examples uses the shared page container", %{conn: conn} do
    body = conn |> get(~p"/examples") |> html_response(200)
    assert body =~ "ds-container"
    refute body =~ "max-w-7xl"
  end

  test "GET / renders the animated hero demo stage the JS module drives", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # The hero demo JS module (assets/js/hero_demo.js) targets this stage by id
    # and cycles its data-step; the markup must ship the stage and the five-step
    # rail it animates.
    assert body =~ ~s(id="hero-demo")
    assert body =~ "pp-stage"
    assert body =~ ~s(data-step="0")

    for label <- ~w(Submit Review Feedback Discuss Resolve) do
      assert body =~ label
    end
  end

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

  describe "GET /terms" do
    test "renders the terms of service page", %{conn: conn} do
      conn = get(conn, ~p"/terms")
      body = html_response(conn, 200)

      assert body =~ "Terms of service"
      # Document-record masthead metadata
      assert body =~ "Effective"
      # A few section headings unique to PerfectPaper's terms
      assert body =~ "Your manuscripts"
      assert body =~ "How PerfectPaper reviews"
      assert body =~ "Credits, plans"
    end

    test "renders a scroll-spy table of contents and back-to-top", %{conn: conn} do
      conn = get(conn, ~p"/terms")
      body = html_response(conn, 200)

      assert body =~ "data-toc-spy"
      assert body =~ "data-toc-link"
      assert body =~ "data-back-to-top"
    end

    test "uses the shared page container, not its old bespoke gutter", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)
      assert body =~ "ds-container"
      refute body =~ "px-5 sm:px-6 lg:px-8"
    end
  end

  test "GET / hero shows the honest affiliation line, not an unsubstantiated count", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Built by NIH-funded cancer researchers"
    refute body =~ "40+ institutions"
  end

  test "the site chrome links to enterprise and testimonials", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ ~s(href="/enterprise")
    assert body =~ ~s(href="/testimonials")
  end

  describe "GET /testimonials" do
    test "renders the placeholder testimonials", %{conn: conn} do
      body = conn |> get(~p"/testimonials") |> html_response(200)

      assert body =~ "What researchers say"

      assert body =~ "Dr. Jordan Avery"
      assert body =~ "Associate Professor of Epidemiology"
      assert body =~ "University of Utah"
      assert body =~ "turned a dreaded revision cycle"

      assert body =~ "Dr. Priya Nair"
      assert body =~ "Postdoctoral Research Fellow"

      assert body =~ "Marcus Bennett"
      assert body =~ "PhD Candidate, Population Health"

      assert body =~ "/images/avatar-placeholder.svg"
    end
  end

  describe "GET /enterprise" do
    test "renders the hub: security block, anchored sections, and contact CTA", %{conn: conn} do
      body = conn |> get(~p"/enterprise") |> html_response(200)

      assert body =~ "Privacy, by design"

      assert body =~ "Your content stays yours"
      assert body =~ "Never used to train AI"
      assert body =~ ~s(href="/enterprise/security")
      assert body =~ ~s(href="#compliance")

      for id <- ~w(security teams access developers compliance support) do
        assert body =~ ~s(id="#{id}")
      end

      assert body =~ "single sign-on" or body =~ "Single sign-on"
      assert body =~ "Webhooks" or body =~ "webhooks"

      assert body =~ "Pursuing"
      refute body =~ "SOC 2 certified"
      refute body =~ "ISO 27001 certified"

      assert body =~ "Contact sales"
      assert body =~ ~s(href="/contact")
    end
  end

  describe "GET /enterprise/security" do
    test "renders the in-depth security page with a back-link", %{conn: conn} do
      body = conn |> get(~p"/enterprise/security") |> html_response(200)

      assert body =~ "Security at PerfectPaper"
      assert body =~ "Encryption"
      assert body =~ "Never used for training"
      assert body =~ "Input sanitization"
      assert body =~ "Retention and deletion"

      assert body =~ "Pursuing"
      refute body =~ "SOC 2 certified"

      assert body =~ ~s(href="/enterprise")
    end
  end

  test "home #pricing shows banded prices for a Mexico (Band B) visitor", %{conn: conn} do
    body = conn |> put_req_header("cf-ipcountry", "MX") |> get(~p"/") |> html_response(200)
    # Band B starter monthly = $30 struck from $40
    assert body =~ "$30"
    assert body =~ "line-through"
    assert body =~ ~s(data-test-id="cadence-annual")
  end

  test "home #pricing shows full price for a US (Band A) visitor", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "$40"
  end

  describe "GET /privacy" do
    test "renders the privacy policy page", %{conn: conn} do
      conn = get(conn, ~p"/privacy")
      body = html_response(conn, 200)

      assert body =~ "Privacy notice"
      # The headline promise: we never train on uploaded drafts
      assert body =~ "train" and body =~ "model"
      assert body =~ "What we collect"
      assert body =~ "How long we keep"
    end

    test "renders a scroll-spy table of contents and back-to-top", %{conn: conn} do
      conn = get(conn, ~p"/privacy")
      body = html_response(conn, 200)

      assert body =~ "data-toc-spy"
      assert body =~ "data-toc-link"
      assert body =~ "data-back-to-top"
    end

    test "uses the shared page container, not its old bespoke gutter", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "ds-container"
      refute body =~ "px-5 sm:px-6 lg:px-8"
    end

    test "privacy notice covers geo pricing + fraud risk-scoring", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "regional pricing" or body =~ "cost-of-living"
      assert body =~ "fraud" and (body =~ "risk" or body =~ "country")
    end
  end
end
