defmodule PerfectPaperWeb.Api.CreditController do
  @moduledoc """
  REST endpoint for a user's credit score. Thin controller → `Credits` context.

  The ledger tracks two derived balances — paid full-review credits and free
  preview credits — surfaced as the Refine-compatible `paidCreditsRemaining` /
  `previewCreditsRemaining` buckets.
  """
  use PerfectPaperWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias PerfectPaper.Credits
  alias PerfectPaperWeb.Api.Schemas

  action_fallback PerfectPaperWeb.Api.FallbackController

  operation(:show,
    summary: "Fetch the authenticated user's credit balance",
    tags: ["Credit"],
    security: [%{"bearerAuth" => []}, %{"apiKeyAuth" => []}],
    responses: [
      ok: {"Credit score", "application/json", Schemas.CreditScore}
    ]
  )

  def show(conn, _params) do
    user_id = conn.assigns.current_user.id

    render(conn, :score,
      paid: Credits.balance(user_id, :paid),
      preview: Credits.balance(user_id, :preview)
    )
  end
end
