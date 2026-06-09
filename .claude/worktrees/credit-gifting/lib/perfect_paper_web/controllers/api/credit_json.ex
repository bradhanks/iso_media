defmodule PerfectPaperWeb.Api.CreditJSON do
  @moduledoc """
  Renders the credit-score response.

  Boundary quirk preserved from the original Refine API: this envelope keeps its
  **camelCase** keys (`paidCreditsRemaining` / `previewCreditsRemaining`) — but
  only here at the REST edge. Everything internal stays snake_case.
  """

  @doc "Renders the credit-score envelope for a user's balance."
  def score(%{paid: paid, preview: preview}) do
    %{paidCreditsRemaining: paid, previewCreditsRemaining: preview}
  end
end
