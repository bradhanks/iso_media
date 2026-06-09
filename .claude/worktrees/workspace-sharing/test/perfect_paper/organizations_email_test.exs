defmodule PerfectPaper.OrganizationsEmailTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias PerfectPaper.Organizations
  alias PerfectPaper.Organizations.Organization

  test "send_invitation/3 invites someone to the organization" do
    org = %Organization{name: "Kepka Lab"}

    assert {:ok, _email} =
             Organizations.send_invitation(
               org,
               "friend@example.com",
               "https://perfectpaper.org/join/abc"
             )

    assert_email_sent(fn email ->
      assert email.to == [{"", "friend@example.com"}]
      assert email.subject =~ "Kepka Lab"
      assert email.html_body =~ "Kepka Lab"
      assert email.html_body =~ "https://perfectpaper.org/join/abc"
    end)
  end
end
