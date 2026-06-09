defmodule PerfectPaper.SSO.ProviderTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.SSO.Provider

  test "for_protocol returns the configured adapter (Stub in test)" do
    assert Provider.for_protocol(:oidc) == PerfectPaper.SSO.Stub
    assert Provider.for_protocol(:saml) == PerfectPaper.SSO.Stub
  end

  test "stub authorize_url + callback shapes" do
    assert {:ok, %{url: url, session_params: %{state: "test"}}} =
             PerfectPaper.SSO.Stub.authorize_url(%{}, %{})

    assert url =~ "idp.test"

    assert {:ok, %{provider: _, uid: _, email: _, email_verified: _}} =
             PerfectPaper.SSO.Stub.callback(%{}, %{}, %{})
  end
end
