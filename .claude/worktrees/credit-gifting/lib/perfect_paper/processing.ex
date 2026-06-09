defmodule PerfectPaper.Processing do
  @moduledoc """
  Read-model over a user's in-flight proofreading work.

  Processing owns no table. It composes a view of "what is happening right now"
  by reading through other contexts' public APIs (currently `History`), so the
  web layer can show progress dashboards without reaching into those contexts'
  internals.
  """
  alias PerfectPaper.{Authz, History}
  alias PerfectPaper.Accounts.User
  alias PerfectPaper.History.Session

  @active_statuses [:pending, :converting, :analyzing]

  @doc """
  A snapshot of the user's current work: the sessions still being processed,
  the sessions the user has not yet opened, and simple counts.
  """
  @spec snapshot(User.t()) :: %{
          active: [Session.t()],
          unviewed: [Session.t()],
          active_count: non_neg_integer(),
          unviewed_count: non_neg_integer()
        }
  def snapshot(%User{} = user) do
    sessions = History.list_sessions(Authz.load_subject(user))
    active = Enum.filter(sessions, &(&1.processing_status in @active_statuses))
    unviewed = Enum.filter(sessions, &(&1.viewed == false))

    %{
      active: active,
      unviewed: unviewed,
      active_count: length(active),
      unviewed_count: length(unviewed)
    }
  end

  @doc "Sessions still being processed (pending/converting/analyzing)."
  @spec active_items(User.t()) :: [Session.t()]
  def active_items(%User{} = user) do
    user
    |> Authz.load_subject()
    |> History.list_sessions()
    |> Enum.filter(&(&1.processing_status in @active_statuses))
  end

  @doc "Completed-or-not sessions the user has not yet opened."
  @spec unviewed_items(User.t()) :: [Session.t()]
  def unviewed_items(%User{} = user) do
    user
    |> Authz.load_subject()
    |> History.list_sessions()
    |> Enum.filter(&(&1.viewed == false))
  end
end
