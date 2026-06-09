defmodule PerfectPaper.WebhooksFixtures do
  @moduledoc "Test fixtures for the Webhooks context."

  alias PerfectPaper.Repo
  alias PerfectPaper.Webhooks.Endpoint

  @doc """
  Inserts an active webhook endpoint for `org`.

  Callers may override any field via `attrs`. Defaults:
  - `url` — `"https://example.com/hook"`
  - `event_types` — `["session.completed"]`
  - `active` — `true`
  - `secret` — a unique test secret

  Fixtures may use `Repo` directly — this is intentional and not a violation
  of the context boundary (fixtures live in the test support tree).
  """
  @spec endpoint_fixture(PerfectPaper.Organizations.Organization.t(), map()) :: Endpoint.t()
  def endpoint_fixture(org, attrs \\ %{}) do
    defaults = %{
      organization_id: org.id,
      url: "https://example.com/hook",
      event_types: ["session.completed"],
      active: true,
      secret: "test_secret_#{System.unique_integer([:positive])}"
    }

    %Endpoint{}
    |> Endpoint.create_changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end
