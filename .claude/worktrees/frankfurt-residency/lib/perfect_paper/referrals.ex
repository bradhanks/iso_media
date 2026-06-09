defmodule PerfectPaper.Referrals do
  @moduledoc """
  Manages the referral program — registering referrals on behalf of a user and
  querying their referral status. Public API and sole `Repo` boundary for the
  Referrals context.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Referrals.{Referral, Notifier}

  @doc """
  Registers a new referral on behalf of `user`. Generates a unique referral
  code and inserts the record. Accepts an optional `:referee_user_id` keyword
  argument.
  """
  @spec register(struct(), keyword()) :: {:ok, Referral.t()} | {:error, Ecto.Changeset.t()}
  def register(user, opts \\ []) do
    code = "pp-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

    attrs = %{
      referrer_user_id: user.id,
      referral_code: code,
      referee_user_id: opts[:referee_user_id]
    }

    with {:ok, referral} <- %Referral{} |> Referral.register_changeset(attrs) |> Repo.insert() do
      if referee = opts[:referee_user_id] do
        # Announce the accepted referral; the Credits campaign rewards the referrer.
        PerfectPaper.Credits.dispatch(:referral_accepted, %{
          referrer_id: user.id,
          referee_id: referee
        })
      end

      {:ok, referral}
    end
  end

  @doc """
  Claims the referral behind `code` for a freshly-signed-up `referee` and
  announces the accepted referral (the Credits campaign rewards the referrer).

  Single-use and guarded: the code must exist and be unclaimed, the referee can't
  be the referrer (no self-referral), and a referee already referred elsewhere is
  not re-linked. Best-effort — returns `{:error, :unavailable}` on any of those
  rather than raising, so it can be called inline from the signup flow.
  """
  @spec accept_referral(String.t(), struct()) :: {:ok, Referral.t()} | {:error, :unavailable}
  def accept_referral(code, %{id: referee_id}) when is_binary(code) and code != "" do
    with %Referral{referee_user_id: nil, referrer_user_id: referrer_id} = referral <-
           Repo.get_by(Referral, referral_code: code),
         true <- referrer_id != referee_id,
         nil <- referrer_id_for(referee_id),
         {:ok, accepted} <-
           referral
           |> Referral.accept_changeset(%{referee_user_id: referee_id, status: :accepted})
           |> Repo.update() do
      # The Credits :referral_accepted campaign rewards the referrer (deduped
      # once-per-referee), so a stray double call can't double-reward.
      PerfectPaper.Credits.dispatch(:referral_accepted, %{
        referrer_id: referrer_id,
        referee_id: referee_id
      })

      {:ok, accepted}
    else
      _ -> {:error, :unavailable}
    end
  end

  def accept_referral(_code, _referee), do: {:error, :unavailable}

  @doc "Returns the user id of whoever referred `referee_user_id`, or nil."
  @spec referrer_id_for(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def referrer_id_for(referee_user_id) do
    Repo.one(
      from r in Referral,
        where: r.referee_user_id == ^referee_user_id,
        order_by: [asc: r.inserted_at],
        limit: 1,
        select: r.referrer_user_id
    )
  end

  @doc "Sends a referral invitation email to a friend on behalf of the referrer."
  @spec send_referral_invitation(struct(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def send_referral_invitation(%{email: referrer_email}, invitee_email, referral_url) do
    Notifier.deliver_referral_invitation(invitee_email, referrer_email, referral_url)
  end

  @doc "Notifies a referrer that they earned a reward when their invitee joined."
  @spec notify_reward_earned(struct(), pos_integer(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def notify_reward_earned(%{email: email}, reward_credits, url) do
    Notifier.deliver_reward_earned(email, reward_credits, url)
  end

  @doc """
  Returns all referrals where the given user is the referrer, ordered newest
  first.
  """
  @spec status(Ecto.UUID.t()) :: [Referral.t()]
  def status(user_id) do
    Repo.all(
      from r in Referral,
        where: r.referrer_user_id == ^user_id,
        order_by: [desc: r.inserted_at]
    )
  end
end
