defmodule PerfectPaper.Marketing do
  @moduledoc """
  Manages user marketing preferences — opt-in status and product update
  subscriptions. Public API and sole `Repo` boundary for the Marketing context.

  Note: this is a data context module. It is distinct from
  `PerfectPaperWeb.Marketing`, which is the web UI layer.
  """

  alias PerfectPaper.Repo
  alias PerfectPaper.Marketing.MarketingPreference

  @doc """
  Returns the marketing preference record for the given user ID, or `nil` if
  none has been set yet.
  """
  @spec get_preferences(Ecto.UUID.t()) :: MarketingPreference.t() | nil
  def get_preferences(user_id) do
    Repo.get_by(MarketingPreference, user_id: user_id)
  end

  @doc """
  Sets the `opt_in` flag for `user`. Creates the preference record if it does
  not yet exist; updates it if it does (upsert — one row per user).
  """
  @spec set_opt_in(struct(), boolean()) ::
          {:ok, MarketingPreference.t()} | {:error, Ecto.Changeset.t()}
  def set_opt_in(user, opt_in) do
    existing = get_preferences(user.id)

    case existing do
      nil ->
        %MarketingPreference{}
        |> MarketingPreference.changeset(%{user_id: user.id, opt_in: opt_in})
        |> Repo.insert()

      preference ->
        preference
        |> MarketingPreference.changeset(%{opt_in: opt_in})
        |> Repo.update()
    end
  end
end
