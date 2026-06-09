defmodule PerfectPaperWeb.Scim.GroupController do
  @moduledoc "SCIM 2.0 Groups endpoint (Entra subset)."
  use PerfectPaperWeb, :controller
  alias PerfectPaper.{Scim, Organizations}
  alias PerfectPaper.Scim.{FilterParser, PatchParser, Group}

  action_fallback PerfectPaperWeb.Scim.FallbackController

  defp org(conn), do: Organizations.get_organization!(conn.assigns.scim_org_id)

  def index(conn, params) do
    resources = Scim.list_groups(conn.assigns.scim_org_id, FilterParser.parse(params["filter"]))

    json(conn, %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      "totalResults" => length(resources),
      "startIndex" => 1,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    })
  end

  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- Scim.get_group_resource(conn.assigns.scim_org_id, id) do
      json(conn, resource)
    end
  end

  def create(conn, params) do
    member_ids = Enum.map(params["members"] || [], & &1["value"])

    with {:ok, group} <-
           Scim.sync_group(org(conn), %{
             external_id: params["externalId"],
             display_name: params["displayName"],
             member_ids: member_ids
           }) do
      conn |> put_status(201) |> json(Group.render(group, Scim.group_member_ids(group.id)))
    end
  end

  # PUT full replace: rename + replace member set.
  def update(conn, %{"id" => id} = params) do
    member_ids = Enum.map(params["members"] || [], & &1["value"])

    with {:ok, group} <-
           Scim.sync_group(org(conn), %{
             external_id: external_id_for(conn, id, params),
             display_name: params["displayName"],
             member_ids: member_ids
           }) do
      json(conn, Group.render(group, Scim.group_member_ids(group.id)))
    end
  end

  def patch(conn, %{"id" => id} = params) do
    with {:ok, ops} <- PatchParser.parse(params),
         :ok <- Scim.patch_group(org(conn), id, ops) do
      # 204 satisfies Entra's confirmation validator and avoids the retry storm.
      send_resp(conn, 204, "")
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Scim.delete_group(conn.assigns.scim_org_id, id) do
      send_resp(conn, 204, "")
    end
  end

  defp external_id_for(conn, id, params) do
    params["externalId"] ||
      case Scim.get_group_resource(conn.assigns.scim_org_id, id) do
        {:ok, %{"externalId" => ext}} -> ext
        _ -> nil
      end
  end
end
