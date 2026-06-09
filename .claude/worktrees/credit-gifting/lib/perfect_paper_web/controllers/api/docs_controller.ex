defmodule PerfectPaperWeb.Api.DocsController do
  @moduledoc """
  Serves a public, brand-themed Redoc HTML reference page at `/api/docs`.

  The page loads the pinned Redoc v2.1.5 standalone bundle from CDN and points
  it at the OpenAPI spec served at `/api/openapi.json`. No authentication is
  required — the route is wired through the `:docs` pipeline.
  """

  use PerfectPaperWeb, :controller

  @redoc_version "v2.1.5"
  @redoc_cdn "https://cdn.redoc.ly/redoc/#{@redoc_version}/bundles/redoc.standalone.js"

  @doc """
  Renders the Redoc HTML reference page.

  Returns a 200 HTML response with an embedded Redoc viewer pointed at
  `/api/openapi.json`, themed to the PerfectPaper brand palette.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    page = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>PerfectPaper API Reference</title>
        <style>
          body {
            margin: 0;
            padding: 0;
            background: #fbf8f2;
            font-family: 'Outfit', 'Helvetica Neue', sans-serif;
          }
        </style>
      </head>
      <body>
        <redoc
          spec-url="/api/openapi.json"
          id="redoc-container">
        </redoc>
        <script src="#{@redoc_cdn}"> </script>
        <script>
          Redoc.init("/api/openapi.json", {
            theme: {
              colors: {
                primary: {
                  main: "#7a2e4e"
                },
                text: {
                  primary: "#211c18"
                }
              },
              typography: {
                fontFamily: "'Outfit', 'Helvetica Neue', sans-serif",
                headings: {
                  fontFamily: "'Fraunces', Georgia, serif"
                }
              },
              rightPanel: {
                backgroundColor: "#1f5e58"
              },
              sidebar: {
                backgroundColor: "#fbf8f2"
              }
            }
          }, document.getElementById("redoc-container"));
        </script>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page)
  end
end
