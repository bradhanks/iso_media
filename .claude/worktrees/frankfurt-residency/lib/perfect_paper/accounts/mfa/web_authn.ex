defmodule PerfectPaper.Accounts.MFA.WebAuthn do
  @moduledoc "WebAuthn hardware-key/passkey adapter. STUB — TODO(mfa): implement registration + assertion ceremonies with a WebAuthn library; store credential id + public key in Factor.secret."
  @behaviour PerfectPaper.Accounts.MFA

  @impl true
  def begin_enrollment(_user, _opts), do: {:error, :not_implemented}

  # TODO(mfa): generate and return WebAuthn registration options (challenge, rp info, user handle).

  @impl true
  def confirm_enrollment(_user, _proof), do: {:error, :not_implemented}
  # TODO(mfa): verify attestation response + persist credential id + public key in Factor.secret.

  @impl true
  def begin_verification(_user), do: {:error, :not_implemented}
  # TODO(mfa): generate and return a WebAuthn assertion challenge + allowed credential ids.

  @impl true
  def verify(_user, _proof), do: {:error, :not_implemented}
  # TODO(mfa): verify assertion signature against the stored public key in Factor.secret.
end
