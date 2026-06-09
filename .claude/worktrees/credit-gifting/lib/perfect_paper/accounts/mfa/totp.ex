defmodule PerfectPaper.Accounts.MFA.TOTP do
  @moduledoc "TOTP authenticator-app adapter. STUB — TODO(mfa): implement with `nimble_totp` (secret gen, otpauth:// URI for QR, 6-digit code verification)."
  @behaviour PerfectPaper.Accounts.MFA

  @impl true
  def begin_enrollment(_user, _opts), do: {:error, :not_implemented}

  # TODO(mfa): generate a TOTP secret + otpauth:// URI for the QR code (NimbleTOTP.secret/otpauth_uri).

  @impl true
  def confirm_enrollment(_user, _proof), do: {:error, :not_implemented}

  # TODO(mfa): verify the first 6-digit code against the pending secret, then persist a confirmed Factor.

  @impl true
  def begin_verification(_user), do: {:error, :not_implemented}
  # TODO(mfa): TOTP needs no server challenge; return an :ok-shaped no-op once implemented.

  @impl true
  def verify(_user, _proof), do: {:error, :not_implemented}
  # TODO(mfa): NimbleTOTP.valid?(secret, code) against the user's confirmed factor.
end
