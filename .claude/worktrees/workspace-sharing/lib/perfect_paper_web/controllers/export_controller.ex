defmodule PerfectPaperWeb.ExportController do
  @moduledoc """
  Downloads a review's manuscript in a chosen format (`markdown` / `docx` /
  `html`). The file is rendered from the canonical document via
  `PerfectPaper.Documents.export/2` and named `<original>_PP.<ext>`.

  Access is authorized through `History.get_session/2`, which returns `nil`
  unless the current user may see the session — so this hides existence the
  same way the workspace does.
  """
  use PerfectPaperWeb, :controller

  alias PerfectPaper.{Authz, Documents, History}
  alias PerfectPaper.Documents.Document
  alias PerfectPaper.History.Session

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id, "format" => format}) do
    scope = Authz.load_subject(conn.assigns.current_scope.user)

    with %Session{document_id: document_id} when is_binary(document_id) <-
           History.get_session(id, scope),
         %Document{} = document <- Documents.get_document(document_id),
         {:ok, file} <- Documents.export(document, format) do
      conn
      |> put_resp_content_type(file.content_type)
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{sanitize(file.filename)}")
      )
      |> send_resp(200, file.content)
    else
      {:error, :unsupported_format} ->
        conn |> put_status(:bad_request) |> text("Unsupported export format.")

      _ ->
        conn |> put_status(:not_found) |> text("Not found.")
    end
  end

  # Keep the filename header safe: strip characters that would break the quoted
  # `filename="…"` value (quotes, control chars, path separators).
  defp sanitize(name), do: String.replace(name, ~r/["\r\n\/\\]/, "")
end
