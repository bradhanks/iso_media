defmodule PerfectPaperWeb.Api.FallbackController do
  @moduledoc """
  Translates context error tuples into the REST API's FastAPI-style error
  envelope: `{"detail": "..."}` for plain errors, and the
  `{"detail": [%{"loc": ..., "msg": ...}]}` form for changeset (422) errors.
  """
  use PerfectPaperWeb, :controller

  def call(conn, {:error, :not_found}), do: detail(conn, 404, "Not found")
  def call(conn, {:error, :comment_not_found}), do: detail(conn, 404, "Comment not found")

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(422)
    |> json(%{detail: changeset_details(changeset)})
  end

  def call(conn, {:error, :unauthorized}), do: detail(conn, 403, "Forbidden")

  def call(conn, {:error, :domain_not_verified}),
    do: detail(conn, 422, "Domain must be verified before SSO can be enabled")

  def call(conn, {:error, :active_contract_exists}),
    do: detail(conn, 409, "An active contract already exists for this organization")

  def call(conn, {:error, _other}), do: detail(conn, 400, "Bad request")

  defp detail(conn, status, message) do
    conn |> put_status(status) |> json(%{detail: message})
  end

  defp changeset_details(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn msg -> %{loc: ["body", field], msg: msg} end)
    end)
  end
end
