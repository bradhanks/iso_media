defmodule PerfectPaperWeb.Scim.FallbackController do
  @moduledoc "Renders domain errors as SCIM Error envelopes (RFC 7644)."
  use PerfectPaperWeb, :controller

  def call(conn, {:error, :not_found}), do: send_error(conn, 404, nil, "Resource not found")

  def call(conn, {:error, :sole_owner}),
    do:
      send_error(
        conn,
        400,
        "mutability",
        "Cannot deactivate the sole organization owner. Please transfer ownership in PerfectPaper before deprovisioning this user."
      )

  def call(conn, {:error, :domain_mismatch}),
    do:
      send_error(
        conn,
        400,
        "invalidValue",
        "userName is outside the organization's verified email domain"
      )

  def call(conn, {:error, :invalid_user_name}),
    do: send_error(conn, 400, "invalidValue", "userName is required")

  def call(conn, {:error, :no_verified_domain}),
    do:
      send_error(
        conn,
        400,
        "invalidValue",
        "Organization has no verified SSO domain; configure SSO before provisioning"
      )

  def call(conn, {:error, :invalid_syntax}),
    do: send_error(conn, 400, "invalidSyntax", "Malformed PATCH request")

  def call(conn, {:error, %Ecto.Changeset{}}),
    do: send_error(conn, 400, "invalidValue", "Request could not be processed")

  def call(conn, {:error, _other}),
    do: send_error(conn, 400, nil, "Request could not be processed")

  defp send_error(conn, status, scim_type, detail) do
    body = %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
      "status" => Integer.to_string(status),
      "detail" => detail
    }

    body = if scim_type, do: Map.put(body, "scimType", scim_type), else: body

    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(status, Jason.encode!(body))
  end
end
