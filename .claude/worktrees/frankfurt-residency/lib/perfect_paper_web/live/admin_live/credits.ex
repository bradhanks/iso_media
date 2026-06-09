defmodule PerfectPaperWeb.AdminLive.Credits do
  @moduledoc """
  Operator-only page to grant goodwill ("comp") credits to an account.

  Look up an account by email, see its current balance, and issue a credit grant
  with a free-form reason. Access is gated to the configured admin allowlist via
  the `:require_admin` on_mount hook. All writes route through the
  `PerfectPaper.Credits` context.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Accounts, Credits}

  @grant_types %{amount: :integer, reason: :string}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Comp credits"),
       target_user: nil,
       balance: nil,
       lookup_error: nil
     )
     |> assign(:lookup_form, to_form(%{"email" => ""}))
     |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))}
  end

  @impl true
  def handle_event("lookup", %{"email" => email}, socket) do
    case Accounts.get_user_by_email(String.trim(email)) do
      nil ->
        {:noreply,
         assign(socket,
           target_user: nil,
           balance: nil,
           lookup_error: gettext("No account found for that email.")
         )}

      user ->
        {:noreply,
         socket
         |> assign(target_user: user, balance: Credits.balance(user.id), lookup_error: nil)
         |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))}
    end
  end

  def handle_event("grant", %{"grant" => params}, %{assigns: %{target_user: user}} = socket)
      when not is_nil(user) do
    case Ecto.Changeset.apply_action(grant_changeset(params), :insert) do
      {:ok, %{amount: amount, reason: reason}} ->
        admin_id = socket.assigns.current_scope.user.id

        case Credits.comp_account(user.id, amount, reason, admin_id) do
          {:ok, _event} ->
            {:noreply,
             socket
             |> assign(balance: Credits.balance(user.id))
             |> assign(:grant_form, to_form(grant_changeset(%{}), as: :grant))
             |> put_flash(
               :info,
               gettext("Granted %{amount} credits to %{email}.",
                 amount: amount,
                 email: user.email
               )
             )}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not record the grant."))}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :grant_form, to_form(changeset, as: :grant))}
    end
  end

  defp grant_changeset(attrs) do
    {%{}, @grant_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@grant_types))
    |> Ecto.Changeset.update_change(:reason, &String.trim/1)
    |> Ecto.Changeset.validate_required([:amount, :reason])
    |> Ecto.Changeset.validate_number(:amount, greater_than: 0)
  end
end
