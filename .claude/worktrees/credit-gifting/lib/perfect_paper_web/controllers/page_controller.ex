defmodule PerfectPaperWeb.PageController do
  use PerfectPaperWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      pricing_band: conn.assigns[:pricing_band] || :a,
      pricing_eu?: PerfectPaper.Billing.Pricing.eu_country?(conn.assigns[:pricing_country])
    )
  end

  def examples(conn, _params) do
    render(conn, :examples)
  end

  def contact(conn, _params) do
    render(conn, :contact)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def testimonials(conn, _params) do
    render(conn, :testimonials)
  end

  def enterprise(conn, _params) do
    render(conn, :enterprise)
  end

  def enterprise_security(conn, _params) do
    render(conn, :enterprise_security)
  end

  def subprocessors(conn, _params) do
    render(conn, :subprocessors)
  end

  def dpa(conn, _params) do
    render(conn, :dpa)
  end
end
