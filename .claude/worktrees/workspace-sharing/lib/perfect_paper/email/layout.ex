defmodule PerfectPaper.Email.Layout do
  @moduledoc """
  Branded, email-safe layout and building blocks for PerfectPaper transactional
  email.

  These are `Phoenix.Component` function components used by every context's
  notifier. Everything is table-based with inline styles and hard-coded brand
  hex values, because mail clients do not load the app's daisyUI/Tailwind CSS
  and frequently strip `<style>` blocks. No external images are referenced, so
  there is nothing for a client to block — the header is a CSS logomark + a
  two-tone wordmark on the warm cream background, mirroring the site header
  (`Perfect` ink · `Paper` mulberry · `.` gold).

  Brand palette (from `BRAND.md` / the `paper` theme):
  Mulberry `#7a2e4e`, Teal `#1f5e58`, Gold `#c28a3a`, Paper cream `#fbf8f2`,
  Ink `#211c18`.
  """
  use Phoenix.Component

  @mulberry "#7a2e4e"
  @teal "#1f5e58"
  @gold "#c28a3a"
  @paper "#fbf8f2"
  @ink "#211c18"
  @muted "#6b6259"
  @hairline "#e6ddd0"

  @font "'Outfit', -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
  @display "'Fraunces', Georgia, 'Times New Roman', serif"

  attr :preview, :string, default: "", doc: "hidden preheader text shown in inbox previews"
  slot :inner_block, required: true

  @doc "The outer branded email shell: preheader, gradient header band, body card, footer."
  def document(assigns) do
    assigns =
      assigns
      |> assign(:mulberry, @mulberry)
      |> assign(:teal, @teal)
      |> assign(:gold, @gold)
      |> assign(:paper, @paper)
      |> assign(:ink, @ink)
      |> assign(:muted, @muted)
      |> assign(:hairline, @hairline)
      |> assign(:font, @font)
      |> assign(:display, @display)

    ~H"""
    <div style={"margin:0;padding:0;background-color:#{@paper};"}>
      <span style="display:none!important;visibility:hidden;opacity:0;color:transparent;height:0;width:0;overflow:hidden;mso-hide:all;">
        {@preview}
      </span>
      <table
        role="presentation"
        width="100%"
        cellpadding="0"
        cellspacing="0"
        border="0"
        style={"background-color:#{@paper};margin:0;padding:0;"}
      >
        <tr>
          <td align="center" style="padding:32px 16px 36px;">
            <table
              role="presentation"
              width="600"
              cellpadding="0"
              cellspacing="0"
              border="0"
              style="width:600px;max-width:600px;"
            >
              <!-- Brand header: logomark + two-tone wordmark, on the cream page -->
              <tr>
                <td style="padding:0 4px 18px;">
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                      <td style={"width:40px;height:40px;background-color:#{@mulberry};border-radius:9px;text-align:center;vertical-align:middle;font-family:#{@display};font-size:23px;font-weight:600;color:#{@paper};line-height:40px;"}>
                        P
                      </td>
                      <td style="width:12px;font-size:0;line-height:0;">&nbsp;</td>
                      <td style="vertical-align:middle;">
                        <span
                          phx-no-format
                          style={"font-family:#{@display};font-size:23px;font-weight:600;letter-spacing:-0.2px;color:#{@ink};"}
                        ><span>Perfect</span><span style={"color:#{@mulberry};"}>Paper</span><span style={"color:#{@gold};"}>.</span></span>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              <!-- Gold hairline rule under the brand -->
              <tr>
                <td style="padding:0 4px;">
                  <div style={"height:2px;line-height:2px;font-size:0;background-color:#{@gold};border-radius:1px;"}>
                    &nbsp;
                  </div>
                </td>
              </tr>
              
    <!-- Content card: white, hairline border, soft radius, sitting on cream -->
              <tr>
                <td style="padding-top:18px;">
                  <table
                    role="presentation"
                    width="100%"
                    cellpadding="0"
                    cellspacing="0"
                    border="0"
                    style={"background-color:#ffffff;border:1px solid #{@hairline};border-radius:10px;"}
                  >
                    <tr>
                      <td style={"padding:34px 36px;font-family:#{@font};font-size:16px;line-height:1.65;color:#{@ink};"}>
                        {render_slot(@inner_block)}
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
              
    <!-- Footer: muted, on cream, no border -->
              <tr>
                <td style={"padding:20px 8px 0;font-family:#{@font};font-size:12px;line-height:1.7;color:#{@muted};"}>
                  <strong style={"color:#{@ink};"}>
                    Perfect<span style={"color:#{@mulberry};"}>Paper</span>
                  </strong>
                  — your AI peer reviewer for academic papers.<br />
                  You're receiving this because you have a PerfectPaper account.
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </div>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  @doc "A bulletproof, table-based call-to-action button in Mulberry."
  def button(assigns) do
    assigns = assigns |> assign(:mulberry, @mulberry) |> assign(:font, @font)

    ~H"""
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0;">
      <tr>
        <td align="center" style={"background-color:#{@mulberry};border-radius:6px;"}>
          <a
            href={@href}
            style={"display:inline-block;padding:13px 26px;font-family:#{@font};font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:6px;"}
          >
            {render_slot(@inner_block)}
          </a>
        </td>
      </tr>
    </table>
    """
  end

  slot :inner_block, required: true

  @doc "A small uppercase eyebrow label in Gold, for section framing."
  def eyebrow(assigns) do
    assigns = assigns |> assign(:gold, @gold) |> assign(:font, @font)

    ~H"""
    <div style={"font-family:#{@font};font-size:12px;font-weight:600;letter-spacing:1.5px;text-transform:uppercase;color:#{@gold};margin-bottom:8px;"}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  @doc "A hairline-bordered panel for highlighting a figure or detail block."
  def panel(assigns) do
    assigns =
      assigns
      |> assign(:paper, @paper)
      |> assign(:hairline, @hairline)
      |> assign(:ink, @ink)
      |> assign(:muted, @muted)
      |> assign(:font, @font)

    ~H"""
    <table
      role="presentation"
      width="100%"
      cellpadding="0"
      cellspacing="0"
      border="0"
      style={"background-color:#{@paper};border:1px solid #{@hairline};border-radius:6px;margin:16px 0;"}
    >
      <tr>
        <td style={"padding:18px 20px;font-family:#{@font};"}>
          <div style={"font-size:12px;text-transform:uppercase;letter-spacing:1px;color:#{@muted};margin-bottom:6px;"}>
            {@title}
          </div>
          <div style={"font-size:16px;color:#{@ink};"}>
            {render_slot(@inner_block)}
          </div>
        </td>
      </tr>
    </table>
    """
  end
end
