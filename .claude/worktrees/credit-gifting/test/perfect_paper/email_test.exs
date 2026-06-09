defmodule PerfectPaper.EmailTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions
  import Phoenix.Component
  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  # A representative branded body built the way notifiers build theirs.
  defp sample_body do
    assigns = %{url: "https://perfectpaper.org/go/abc"}

    ~H"""
    <.document preview="A short preview line">
      <.eyebrow>Welcome</.eyebrow>
      <p>Hello there.</p>
      <.button href={@url}>Take action</.button>
    </.document>
    """
  end

  describe "deliver/4" do
    test "sends from the configured sender identity" do
      assert {:ok, _email} = Email.deliver("reader@example.com", "Hi", sample_body(), "plain")

      assert_email_sent(fn email ->
        assert email.from == {"PerfectPaper", "no-reply@perfectpaper.org"}
        assert email.to == [{"", "reader@example.com"}]
        assert email.subject == "Hi"
      end)
    end

    test "renders the branded HTML layout with the wordmark and the button URL" do
      assert {:ok, _email} = Email.deliver("reader@example.com", "Hi", sample_body(), "plain")

      assert_email_sent(fn email ->
        assert email.html_body =~ "PerfectPaper"
        assert email.html_body =~ "https://perfectpaper.org/go/abc"
        assert email.html_body =~ "Take action"
      end)
    end

    test "carries the explicit plaintext fallback so links survive in text-only clients" do
      text = "Take action: https://perfectpaper.org/go/abc"
      assert {:ok, _email} = Email.deliver("reader@example.com", "Hi", sample_body(), text)

      assert_email_sent(fn email ->
        assert email.text_body == text
      end)
    end
  end
end
