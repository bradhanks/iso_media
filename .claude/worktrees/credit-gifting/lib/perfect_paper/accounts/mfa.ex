defmodule PerfectPaper.Accounts.MFA do
  @moduledoc """
  The MFA seam: a behaviour with config-selected adapters per factor type
  (TOTP, WebAuthn), following the repo's anti-corruption-layer pattern. Adapters
  return atom-keyed maps matching `Factor` fields. SCAFFOLD: adapters are stubs
  returning `{:error, :not_implemented}` — see `TODO(mfa)` markers.
  """
  alias PerfectPaper.Accounts.MFA

  @type user :: %{id: Ecto.UUID.t()}
  @type factor_type :: :totp | :webauthn

  @callback begin_enrollment(user(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback confirm_enrollment(user(), term()) :: {:ok, map()} | {:error, term()}
  @callback begin_verification(user()) :: {:ok, map()} | {:error, term()}
  @callback verify(user(), term()) :: :ok | {:error, term()}

  @doc "Begins enrollment of a factor of `type` for `user` (dispatches to the configured adapter)."
  @spec begin_enrollment(user(), factor_type()) :: {:ok, map()} | {:error, term()}
  def begin_enrollment(user, type), do: adapter(type).begin_enrollment(user, [])

  @doc "Confirms a pending enrollment with the user's first proof."
  @spec confirm_enrollment(user(), factor_type(), term()) :: {:ok, map()} | {:error, term()}
  def confirm_enrollment(user, type, proof), do: adapter(type).confirm_enrollment(user, proof)

  @doc "Begins a verification challenge at login."
  @spec begin_verification(user(), factor_type()) :: {:ok, map()} | {:error, term()}
  def begin_verification(user, type), do: adapter(type).begin_verification(user)

  @doc "Verifies a proof (code/assertion) for `type`."
  @spec verify(user(), factor_type(), term()) :: :ok | {:error, term()}
  def verify(user, type, proof), do: adapter(type).verify(user, proof)

  defp adapter(:totp), do: config(:totp, MFA.TOTP)
  defp adapter(:webauthn), do: config(:webauthn, MFA.WebAuthn)

  defp config(type, default),
    do: Application.get_env(:perfect_paper, :mfa_adapters, [])[type] || default
end
