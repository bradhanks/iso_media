defmodule PerfectPaper.Teams.Bot do
  @moduledoc """
  Outbound Bot Framework send. `reply/2` answers an inbound activity;
  `send_proactive/2` pushes a card to a stored conversation reference.
  Config-selected adapter (stub default); the real Bot Connector adapter
  (app token + POST to serviceUrl) is `TODO(teams)`.
  """

  @doc "Sends a reply card to an inbound activity's conversation reference."
  @callback reply(conversation_reference :: map(), card :: map()) :: :ok | {:error, term()}

  @doc "Sends a proactive card to a stored conversation reference."
  @callback send_proactive(conversation_reference :: map(), card :: map()) ::
              :ok | {:error, term()}

  @doc "Returns the configured adapter module (default: Stub)."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :perfect_paper,
      :teams_bot,
      PerfectPaper.Teams.Bot.Stub
    )
  end

  @doc """
  Replies to an inbound activity via the configured adapter.

  `conversation_reference` is the map extracted from the inbound Activity and
  stored on the `Teams.Link`. `card` is an Adaptive Card map produced by
  `Teams.Card`.
  """
  @spec reply(map(), map()) :: :ok | {:error, term()}
  def reply(ref, card), do: adapter().reply(ref, card)

  @doc """
  Sends a proactive notification card to a linked user's stored conversation
  reference via the configured adapter. Used by `Teams.notify/3` and the
  `NotifyWorker`.
  """
  @spec send_proactive(map(), map()) :: :ok | {:error, term()}
  def send_proactive(ref, card), do: adapter().send_proactive(ref, card)
end
