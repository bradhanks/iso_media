defmodule PerfectPaperWeb.Scim.UserController do
  @moduledoc "SCIM 2.0 Users endpoint (Entra subset)."
  use PerfectPaperWeb, :controller
  alias PerfectPaper.{Scim, Organizations}
  alias PerfectPaper.Scim.{FilterParser, PatchParser, User}

  action_fallback PerfectPaperWeb.Scim.FallbackController

  defp org(conn), do: Organizations.get_organization!(conn.assigns.scim_org_id)

  def index(conn, params) do
    resources = Scim.list_users(conn.assigns.scim_org_id, FilterParser.parse(params["filter"]))
    json(conn, list_response(resources, params))
  end

  def show(conn, %{"id" => id}) do
    with {:ok, resource} <- Scim.get_user_resource(conn.assigns.scim_org_id, id) do
      json(conn, resource)
    end
  end

  def create(conn, params) do
    with {:ok, user} <- Scim.provision_user(org(conn), User.from_params(params)) do
      membership = Organizations.get_membership(conn.assigns.scim_org_id, user.id)

      conn
      |> put_status(201)
      |> json(User.render(user, membership, params["externalId"] || params["userName"]))
    end
  end

  # PUT full replace: active=false deactivates; otherwise (re)provision.
  def update(conn, %{"id" => id} = params) do
    attrs = User.from_params(params)

    if attrs.active == false do
      with {:ok, _} <- Scim.deactivate_user(org(conn), id),
           {:ok, resource} <- Scim.get_user_resource(conn.assigns.scim_org_id, id) do
        json(conn, resource)
      end
    else
      with {:ok, user} <- Scim.provision_user(org(conn), attrs) do
        membership = Organizations.get_membership(conn.assigns.scim_org_id, user.id)
        json(conn, User.render(user, membership, params["externalId"]))
      end
    end
  end

  def patch(conn, %{"id" => id} = params) do
    with {:ok, ops} <- PatchParser.parse(params),
         :ok <- apply_each(conn, id, ops),
         {:ok, resource} <- Scim.get_user_resource(conn.assigns.scim_org_id, id) do
      json(conn, resource)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Scim.deactivate_user(org(conn), id) do
      send_resp(conn, 204, "")
    end
  end

  # Applies parsed user ops, halting (and surfacing the error to the
  # FallbackController) on any failure — never swallows a deactivate/reactivate error.
  defp apply_each(conn, id, ops) do
    Enum.reduce_while(ops, :ok, fn
      {:set_active, false}, _ ->
        case Scim.deactivate_user(org(conn), id) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:set_active, true}, _ ->
        case Scim.reactivate_user(org(conn), id) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _other, _ ->
        {:cont, :ok}
    end)
  end

  defp list_response(resources, params) do
    %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
      "totalResults" => length(resources),
      "startIndex" => to_int(params["startIndex"], 1),
      "itemsPerPage" => length(resources),
      "Resources" => resources
    }
  end

  defp to_int(nil, default), do: default

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(_, default), do: default
end
