defmodule PerfectPaperWeb.Api.Spec do
  @moduledoc """
  The OpenAPI specification for the PerfectPaper REST API (code-derived).

  Implements the `OpenApiSpex.OpenApi` behaviour so it can be attached to the
  router pipeline via `OpenApiSpex.Plug.PutApiSpec` and served at
  `GET /api/openapi.json` via `OpenApiSpex.Plug.RenderSpec`.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias PerfectPaperWeb.{Endpoint, Router}

  @doc """
  Returns the `%OpenApiSpex.OpenApi{}` spec struct for the PerfectPaper REST API.

  Two security schemes are documented:
  - `bearerAuth` — a session token issued by `/users/log-in`, passed as
    `Authorization: Bearer <token>` (takes precedence).
  - `apiKeyAuth` — a long-lived API key created via the account surface,
    also passed as `Authorization: Bearer <key>` (resolved by
    `ApiKeys.verify/1`).
  """
  @impl OpenApiSpex.OpenApi
  @spec spec() :: OpenApi.t()
  def spec do
    %OpenApi{
      info: %Info{
        title: "PerfectPaper API",
        version: to_string(Application.spec(:perfect_paper, :vsn)),
        description:
          "REST API for PerfectPaper — upload manuscripts, get referee-grade feedback, act on it."
      },
      servers: [Server.from_endpoint(Endpoint)],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "Session token via Authorization: Bearer <token> (takes precedence over an API key)."
          },
          "apiKeyAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "API key via Authorization: Bearer <key>, resolved by ApiKeys.verify/1."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
