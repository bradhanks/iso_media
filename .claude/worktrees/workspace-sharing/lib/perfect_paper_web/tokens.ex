defmodule PerfectPaperWeb.Tokens do
  @moduledoc """
  Resolves an `Authorization: Bearer <value>` into a user for the REST API.

  Two kinds of bearer value are accepted, matching the original spec's
  "API key or session token" scheme:

    1. An **API key** (`pp_…`), verified via `PerfectPaper.ApiKeys.verify/1`.
    2. A **session token**, base64url-encoded (the raw token is binary), verified
       via `PerfectPaper.Accounts.get_user_by_session_token/1`.

  The API key is tried first since it is the common SDK path. This is the
  header/API side of auth; `PerfectPaperWeb.UserAuth` owns the cookie/LiveView side.
  """
  alias PerfectPaper.{Accounts, ApiKeys}

  @doc "Resolves a bearer value to `{:ok, user}` or `{:error, :invalid}`."
  @spec user_for_bearer(String.t()) :: {:ok, struct()} | {:error, :invalid}
  def user_for_bearer(value) when is_binary(value) do
    case user_from_api_key(value) do
      {:ok, user} -> ensure_active(user)
      :error -> with {:ok, user} <- user_from_session_token(value), do: ensure_active(user)
    end
  end

  # A deactivated (directory-deprovisioned) user can hold no bearer credential —
  # mirrors the cookie/LiveView gate in UserAuth.fetch_current_scope_for_user.
  defp ensure_active(%{deactivated_at: nil} = user), do: {:ok, user}
  defp ensure_active(_), do: {:error, :invalid}

  defp user_from_api_key(value) do
    with {:ok, key} <- ApiKeys.verify(value),
         %{} = user <- Accounts.get_user(key.user_id) do
      {:ok, user}
    else
      # Invalid token, or a key whose user no longer exists: fail closed (401)
      # rather than raising a 500.
      _ -> :error
    end
  end

  defp user_from_session_token(value) do
    # TODO(mfa): require a verified MFA factor before issuing/accepting a session
    # bearer token for an MFA-required user (Accounts.mfa_required_for?/1). See Spec 6.
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         %{} = user <- Accounts.get_user_by_session_token(decoded) do
      {:ok, user}
    else
      _ -> {:error, :invalid}
    end
  end
end
