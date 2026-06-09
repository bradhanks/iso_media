defmodule PerfectPaper.Credits.Campaign do
  @moduledoc """
  A composable credit-grant rule, built with pipeable functions and interpreted
  by the `PerfectPaper.Credits` context.

  Three loosely-coupled axes compose independently — *what* is granted, *when*,
  and the *policy/exceptions* — so none knows about the others:

      grant_credit(:preview, 1, "referral_accepted", to: :referrer_id)
      |> grant_when(:referral_accepted)
      |> grant_when(fn ctx -> ctx.referrer_id != ctx.referee_id end)
      |> grant_filter(:once_per, key: &"referral_accepted:\#{&1.referee_id}")

  The builders are pure data transforms (the functional core); `run_campaign/2`
  in the context interprets the spec and performs the grant (the imperative
  shell). Generosity lives entirely in the data — change amounts, triggers, or
  policies without touching the mechanics.
  """

  @type effect ::
          {:grant, :paid | :preview, pos_integer(), String.t()}
          | {:convert, :paid | :preview, :paid | :preview, pos_integer(), String.t()}

  @type t :: %__MODULE__{
          effect: effect() | nil,
          trigger: atom() | nil,
          target: atom(),
          guards: [(map() -> boolean())],
          filters: [{atom(), keyword()}]
        }

  defstruct effect: nil, trigger: nil, target: :user_id, guards: [], filters: []

  @doc """
  Starts a campaign that grants `amount` credits of `kind` (`:paid` | `:preview`).
  `:to` names the context key holding the recipient's user id (default `:user_id`).
  """
  @spec grant_credit(:paid | :preview, pos_integer(), String.t(), keyword()) :: t()
  def grant_credit(kind, amount, reason, opts \\ [])
      when kind in [:paid, :preview] and is_integer(amount) and amount > 0 do
    %__MODULE__{effect: {:grant, kind, amount, reason}, target: Keyword.get(opts, :to, :user_id)}
  end

  @doc "Starts a campaign that converts `amount` credits from one bucket to another."
  @spec convert_credit(:paid | :preview, :paid | :preview, pos_integer(), String.t(), keyword()) ::
          t()
  def convert_credit(from, to, amount, reason, opts \\ [])
      when from in [:paid, :preview] and to in [:paid, :preview] and is_integer(amount) and
             amount > 0 do
    %__MODULE__{
      effect: {:convert, from, to, amount, reason},
      target: Keyword.get(opts, :to, :user_id)
    }
  end

  @doc """
  Sets the triggering event (an atom), or — given a 1-arity function — adds a
  guard predicate `(ctx -> boolean)` that must hold for the grant to fire.
  """
  @spec grant_when(t(), atom() | (map() -> boolean())) :: t()
  def grant_when(%__MODULE__{} = campaign, trigger) when is_atom(trigger),
    do: %{campaign | trigger: trigger}

  def grant_when(%__MODULE__{} = campaign, guard) when is_function(guard, 1),
    do: %{campaign | guards: campaign.guards ++ [guard]}

  @doc """
  Attaches a policy/exception filter. Supported policies:

  - `:once_per` — `key: (ctx -> String.t())`, grants at most once per derived key
    (idempotency / "don't reward the same referral twice").
  """
  @spec grant_filter(t(), atom(), keyword()) :: t()
  def grant_filter(%__MODULE__{} = campaign, policy, opts \\ []) when is_atom(policy),
    do: %{campaign | filters: campaign.filters ++ [{policy, opts}]}
end
