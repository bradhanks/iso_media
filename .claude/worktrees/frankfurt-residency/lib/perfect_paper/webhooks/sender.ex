defmodule PerfectPaper.Webhooks.Sender do
  @moduledoc """
  Outbound webhook HTTP behaviour (anti-corruption layer).
  Config: `config :perfect_paper, :webhook_sender, MyAdapter`.
  Default: `PerfectPaper.Webhooks.Sender.Req`.
  Test: `PerfectPaper.Webhooks.Sender.Stub`.
  """

  @callback deliver(url :: String.t(), body :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, status :: integer()} | {:error, term()}

  @doc "Returns the configured adapter module."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:perfect_paper, :webhook_sender, PerfectPaper.Webhooks.Sender.Req)
  end

  @doc "Delegates to the configured adapter."
  @spec deliver(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, integer()} | {:error, term()}
  def deliver(url, body, headers), do: adapter().deliver(url, body, headers)
end
