defmodule PerfectPaper.ApiKeysFixtures do
  @moduledoc "Test fixtures for the ApiKeys context."

  alias PerfectPaper.ApiKeys

  import PerfectPaper.AccountsFixtures, only: [user_fixture: 0]

  @doc "Issues a key for a (fresh or given) user; returns raw token + record + user."
  def api_key_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    user = attrs[:user] || user_fixture()
    {:ok, raw, key} = ApiKeys.generate(user, attrs[:name] || "default")
    %{raw: raw, key: key, user: user}
  end
end
