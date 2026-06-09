defmodule PerfectPaperWeb.ReferralController do
  @moduledoc """
  Referral landing. A shared `/join?ref=<code>` link stashes the code in the
  session and sends the visitor to registration; the registration LiveView claims
  it when the new account is created (see `UserLive.Registration`).
  """
  use PerfectPaperWeb, :controller

  @doc "Stores the referral code (if any) in the session and redirects to sign-up."
  def join(conn, params) do
    conn
    |> stash_ref(params["ref"])
    |> redirect(to: ~p"/users/register")
  end

  defp stash_ref(conn, ref) when is_binary(ref) and ref != "",
    do: put_session(conn, :referral_code, ref)

  defp stash_ref(conn, _ref), do: conn
end
