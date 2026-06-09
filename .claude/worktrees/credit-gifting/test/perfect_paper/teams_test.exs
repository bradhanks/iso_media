defmodule PerfectPaper.TeamsTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{Teams, Accounts, SSO}
  alias PerfectPaper.Accounts.Scope
  alias PerfectPaper.Teams.Activity

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures

  setup do
    # The Bot stub records sends to the process registered here, so the test can
    # assert on replies / proactive cards.
    Process.put(:teams_bot_pid, self())

    owner = user_fixture()
    org = organization_fixture(owner)
    scope = Scope.for_user(owner)

    {:ok, _} =
      SSO.configure_sso(org, scope, %{
        protocol: :oidc,
        email_domain: "acme.com",
        oidc_tenant_id: "tenant-1",
        oidc_client_id: "c",
        oidc_client_secret: "s"
      })

    {:ok, _} = SSO.verify_domain(org, scope)
    {:ok, _} = SSO.enable_sso(org, scope, true)

    {:ok, _} =
      Accounts.create_identity(owner, %{
        provider: "oidc:#{org.id}",
        provider_uid: "aad-1",
        provider_email: owner.email
      })

    %{owner: owner, org: org}
  end

  defp install_activity(oid, tenant) do
    Activity.parse(%{
      "type" => "conversationUpdate",
      "from" => %{"aadObjectId" => oid},
      "channelData" => %{"tenant" => %{"id" => tenant}},
      "serviceUrl" => "https://smba/",
      "conversation" => %{"id" => "c1"},
      "recipient" => %{"id" => "bot"}
    })
  end

  test "install with a matching AAD oid (same tenant) links the user + replies welcome",
       %{owner: owner} do
    :ok = Teams.handle_activity(install_activity("aad-1", "tenant-1"), %{})

    assert Teams.get_link_by_user(owner.id)
    assert_receive {:teams_reply, _ref, %{"body" => _}}
  end

  test "cross-tenant oid does NOT link (replies link prompt)", %{owner: owner} do
    :ok = Teams.handle_activity(install_activity("aad-1", "WRONG-tenant"), %{})

    refute Teams.get_link_by_user(owner.id)
    assert_receive {:teams_reply, _ref, %{"actions" => _}}
  end

  test "unknown oid replies a link prompt (fallback)" do
    :ok = Teams.handle_activity(install_activity("aad-unknown", "tenant-1"), %{})

    assert_receive {:teams_reply, _ref, %{"actions" => _}}
  end

  test "mute then unmute toggles the flag", %{owner: owner} do
    :ok = Teams.handle_activity(install_activity("aad-1", "tenant-1"), %{})

    :ok =
      Teams.handle_activity(
        %Activity{
          type: "message",
          text: "mute",
          aad_object_id: "aad-1",
          tenant_id: "tenant-1",
          conversation_reference: %{}
        },
        %{}
      )

    assert Teams.get_link_by_user(owner.id).muted

    :ok =
      Teams.handle_activity(
        %Activity{
          type: "message",
          text: "unmute",
          aad_object_id: "aad-1",
          tenant_id: "tenant-1",
          conversation_reference: %{}
        },
        %{}
      )

    refute Teams.get_link_by_user(owner.id).muted
  end

  test "deep-link token round-trips: redeem binds the logged-in user", %{owner: owner} do
    token =
      Teams.issue_link_token(%{
        aad_object_id: "aad-x",
        tenant_id: "tenant-1",
        conversation_reference: %{},
        service_url: "https://smba/"
      })

    assert {:ok, _link} = Teams.redeem_link_token(owner, token)
    assert Teams.get_link_by_user(owner.id).aad_object_id == "aad-x"
  end
end
