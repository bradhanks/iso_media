defmodule PerfectPaper.DocumentsEmailTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias PerfectPaper.Documents
  alias PerfectPaper.Documents.Document

  test "notify_proofreading_complete/3 tells the writer their review is ready" do
    user = %{id: "u-1", email: "writer@example.com"}
    document = %Document{filename: "thesis.pdf"}

    assert {:ok, _email} =
             Documents.notify_proofreading_complete(
               user,
               document,
               "https://perfectpaper.org/review/1"
             )

    assert_email_sent(fn email ->
      assert email.to == [{"", "writer@example.com"}]
      assert email.subject =~ "thesis.pdf"
      assert email.html_body =~ "thesis.pdf"
      assert email.html_body =~ "https://perfectpaper.org/review/1"
    end)
  end
end
