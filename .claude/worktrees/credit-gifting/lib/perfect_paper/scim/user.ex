defmodule PerfectPaper.Scim.User do
  @moduledoc """
  Renders an `Accounts.User` + org membership as a SCIM User resource, and
  extracts our internal attrs from an inbound SCIM User payload.
  """
  alias PerfectPaper.Accounts.User
  alias PerfectPaper.Organizations.Membership

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"

  @doc "Renders a SCIM User resource map (for JSON encoding)."
  @spec render(User.t(), Membership.t() | nil, String.t() | nil) :: map()
  def render(%User{} = user, membership, external_id) do
    active = is_nil(user.deactivated_at) and (is_nil(membership) or membership.status == :active)

    %{
      "schemas" => [@user_schema],
      "id" => user.id,
      "externalId" => external_id,
      "userName" => user.email,
      "active" => active,
      "emails" => [%{"value" => user.email, "primary" => true}],
      "meta" => %{"resourceType" => "User", "location" => "/scim/v2/Users/#{user.id}"}
    }
  end

  @doc "Extracts our internal (atom-keyed) attrs from an inbound SCIM User JSON map."
  @spec from_params(map()) :: map()
  def from_params(params) do
    %{
      external_id: params["externalId"] || params["userName"],
      user_name: params["userName"],
      display_name: params["displayName"] || get_in(params, ["name", "formatted"]),
      active: Map.get(params, "active", true)
    }
  end
end
