defmodule PerfectPaper.Workspaces do
  @moduledoc """
  Workspaces — a user's lightweight, switchable containers for grouping reviews.
  This is the public API and the only `Repo` boundary for workspaces. Every
  function authorizes on `workspace.user_id == user.id` (v1 is solo; membership
  comes later).
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Accounts.User
  alias PerfectPaper.Workspaces.Workspace

  @doc "The user's workspaces, Personal pinned first, then alphabetical."
  @spec list_workspaces(User.t()) :: [Workspace.t()]
  def list_workspaces(%User{id: uid}) do
    Repo.all(
      from w in Workspace,
        where: w.user_id == ^uid,
        order_by: [desc: w.is_personal, asc: w.name]
    )
  end

  @doc """
  Ensure-and-return the user's Personal workspace. Concurrency-safe: if a
  parallel request wins the insert, we re-read the existing row instead of
  raising on the partial unique index.
  """
  @spec personal_workspace(User.t()) :: Workspace.t()
  def personal_workspace(%User{} = user) do
    case Repo.get_by(Workspace, user_id: user.id, is_personal: true) do
      %Workspace{} = ws -> ws
      nil -> insert_personal(user)
    end
  end

  defp insert_personal(user) do
    case user |> Workspace.personal_changeset() |> Repo.insert() do
      {:ok, ws} -> ws
      {:error, _changeset} -> Repo.get_by!(Workspace, user_id: user.id, is_personal: true)
    end
  end

  @doc "Fetch a workspace the user owns (hides existence otherwise)."
  @spec get_workspace(Ecto.UUID.t(), User.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id, %User{id: uid}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get_by(Workspace, id: uuid, user_id: uid) do
          %Workspace{} = ws -> {:ok, ws}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Create a (non-personal) workspace owned by the user."
  @spec create_workspace(User.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_workspace(%User{} = user, attrs) do
    %Workspace{}
    |> Workspace.create_changeset(Map.put(Map.new(attrs), :user_id, user.id))
    |> Repo.insert()
  end

  @doc "Rename a workspace the user owns (Personal allowed)."
  @spec rename_workspace(Workspace.t(), User.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, term()}
  def rename_workspace(%Workspace{user_id: uid} = ws, %User{id: uid}, name) do
    ws |> Workspace.rename_changeset(%{name: name}) |> Repo.update()
  end

  def rename_workspace(%Workspace{}, %User{}, _name), do: {:error, :not_found}

  @doc """
  Delete a non-Personal workspace the user owns. Its reviews are first reassigned
  to the user's Personal workspace (via `History.reassign_reviews/2` — History
  owns the sessions table), then the workspace row is deleted.
  """
  @spec delete_workspace(Workspace.t(), User.t()) ::
          {:ok, Workspace.t()} | {:error, :personal | :not_found | term()}
  def delete_workspace(%Workspace{is_personal: true}, %User{}), do: {:error, :personal}

  def delete_workspace(%Workspace{user_id: uid} = ws, %User{id: uid} = user) do
    personal = personal_workspace(user)

    # Atomic: reassigning the reviews and deleting the workspace must commit
    # together, so a failed delete can't strand the sessions already moved to
    # Personal (leaving an "empty" workspace that should have been removed).
    Repo.transaction(fn ->
      {:ok, _count} = PerfectPaper.History.reassign_reviews(ws.id, personal.id)

      case Repo.delete(ws) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def delete_workspace(%Workspace{}, %User{}), do: {:error, :not_found}

  @doc """
  Persist the user's last-used workspace default. Workspaces authorizes that the
  user owns the workspace; the `users` write is delegated to Accounts, which owns
  that table (architecture boundary).
  """
  @spec set_active(User.t(), Ecto.UUID.t()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_active(%User{} = user, workspace_id) do
    case get_workspace(workspace_id, user) do
      {:ok, ws} -> PerfectPaper.Accounts.set_active_workspace(user, ws.id)
      {:error, :not_found} -> {:error, :not_found}
    end
  end
end
