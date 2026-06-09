defmodule PerfectPaper.ApiKeys do
  @moduledoc """
  Issue, list, revoke, and verify API keys. Public API and sole `Repo` boundary
  for the ApiKeys context. Raw tokens are shown once at creation; only their
  SHA-256 hash is stored.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.ApiKeys.ApiKey

  @prefix "pp_"

  @doc """
  Issues a new key for a user. Returns the raw token (show it once) alongside the
  stored record.
  """
  @spec generate(struct(), String.t()) ::
          {:ok, String.t(), ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def generate(user, name) do
    secret = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    raw = @prefix <> secret

    attrs = %{name: name, prefix: @prefix, token_hash: hash(raw), user_id: user.id}

    case %ApiKey{} |> ApiKey.create_changeset(attrs) |> Repo.insert() do
      {:ok, key} -> {:ok, raw, key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Lists a user's active (non-revoked) keys."
  @spec list_keys(Ecto.UUID.t()) :: [ApiKey.t()]
  def list_keys(user_id) do
    Repo.all(from k in ApiKey, where: k.user_id == ^user_id and is_nil(k.revoked_at))
  end

  @doc "Revokes a key so it can no longer authenticate."
  @spec revoke_key(ApiKey.t()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def revoke_key(%ApiKey{} = key) do
    key
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Revokes all of a user's still-active API keys (e.g. on directory
  deprovisioning). Atomic; returns the number of keys revoked.
  """
  @spec revoke_all_for_user(Ecto.UUID.t()) :: non_neg_integer()
  def revoke_all_for_user(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(k in ApiKey, where: k.user_id == ^user_id and is_nil(k.revoked_at)),
        set: [revoked_at: now]
      )

    count
  end

  # Throttle last_used_at writes: at most one update per key per this many
  # seconds, so a busy SDK caller doesn't write the row on every request.
  @last_used_throttle_seconds 60

  @doc """
  Verifies a raw token, returning the active key it belongs to and stamping its
  `last_used_at` (throttled to at most once per minute).
  """
  @spec verify(String.t()) :: {:ok, ApiKey.t()} | {:error, :invalid}
  def verify(raw) when is_binary(raw) do
    case Repo.one(from k in ApiKey, where: k.token_hash == ^hash(raw) and is_nil(k.revoked_at)) do
      nil -> {:error, :invalid}
      key -> {:ok, touch_last_used(key)}
    end
  end

  defp touch_last_used(%ApiKey{} = key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if is_nil(key.last_used_at) or
         DateTime.diff(now, key.last_used_at) >= @last_used_throttle_seconds do
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id), set: [last_used_at: now])
      %{key | last_used_at: now}
    else
      key
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
