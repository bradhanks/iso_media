defmodule PerfectPaper.Scim.Group do
  @moduledoc "Renders an org `Group` as a SCIM Group resource."
  alias PerfectPaper.Organizations.Group

  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  @doc "Renders a SCIM Group resource map (for JSON encoding)."
  @spec render(Group.t(), [Ecto.UUID.t()]) :: map()
  def render(%Group{} = group, member_ids) do
    %{
      "schemas" => [@group_schema],
      "id" => group.id,
      "externalId" => group.scim_external_id,
      "displayName" => group.name,
      "members" => Enum.map(member_ids, &%{"value" => &1}),
      "meta" => %{"resourceType" => "Group", "location" => "/scim/v2/Groups/#{group.id}"}
    }
  end
end
