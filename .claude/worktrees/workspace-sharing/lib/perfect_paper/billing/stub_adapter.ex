defmodule PerfectPaper.Billing.StubAdapter do
  @moduledoc """
  Deterministic stub implementation of `PerfectPaper.Billing.Provider`.

  Used in development and test environments. Performs no real IO — all responses
  are generated locally with a random suffix so tests can assert on the returned
  provider IDs without relying on a live payments API.

  Selected via `config :perfect_paper, :billing_provider, PerfectPaper.Billing.StubAdapter`.
  """

  @behaviour PerfectPaper.Billing.Provider

  @doc "Stub: returns a deterministic customer ID with a random suffix."
  @spec create_customer(map()) :: {:ok, %{provider_customer_id: String.t()}}
  @impl PerfectPaper.Billing.Provider
  def create_customer(_attrs) do
    {:ok, %{provider_customer_id: "cus_stub_" <> rand()}}
  end

  @doc "Stub: returns a deterministic subscription ID and active status."
  @spec create_subscription(map()) ::
          {:ok, %{provider_subscription_id: String.t(), status: :active}}
  @impl PerfectPaper.Billing.Provider
  def create_subscription(_attrs) do
    {:ok, %{provider_subscription_id: "sub_stub_" <> rand(), status: :active}}
  end

  @doc "Stub: returns a canceled status for any subscription ID."
  @spec cancel_subscription(String.t()) :: {:ok, %{status: :canceled}}
  @impl PerfectPaper.Billing.Provider
  def cancel_subscription(_provider_subscription_id) do
    {:ok, %{status: :canceled}}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp rand do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
