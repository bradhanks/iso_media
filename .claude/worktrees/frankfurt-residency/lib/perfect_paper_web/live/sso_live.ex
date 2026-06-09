defmodule PerfectPaperWeb.SsoLive do
  @moduledoc """
  Org-admin enterprise SSO setup: configure the OIDC / SAML credentials, verify
  the email domain, and enable or disable single sign-on.

  Mount gates on org-admin status: the org is loaded from `:org_id`, and a user
  who is not an admin of that org (or an unknown org) is redirected away with a
  flash. Secret material is never rendered — the OIDC client secret and the SAML
  IdP certificate are shown only as "set / not set" status.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Authz, Organizations, SSO}

  @impl true
  def mount(%{"org_id" => org_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, org} <- Organizations.get_organization(org_id),
         true <- Organizations.admin?(org, user.id) do
      {:ok, load(socket, org, Authz.load_subject(user))}
    else
      _ ->
        socket =
          socket
          |> put_flash(:error, gettext("You must be an organization admin to manage SSO."))
          |> push_navigate(to: ~p"/new")

        {:ok, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_protocol", %{"protocol" => protocol}, socket)
      when protocol in ["oidc", "saml"] do
    {:noreply, assign(socket, selected_protocol: String.to_existing_atom(protocol))}
  end

  def handle_event("configure", %{"config" => params}, socket) do
    %{org: org, scope: scope} = socket.assigns

    case SSO.configure_sso(org, scope, SSO.config_attrs(params)) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config, selected_protocol: config.protocol, form_errors: %{})
         |> put_flash(:info, gettext("SSO configuration saved."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not authorized to configure SSO."))}

      {:error, changeset} ->
        {:noreply, assign(socket, form_errors: traverse(changeset))}
    end
  end

  def handle_event("verify_domain", _params, socket) do
    %{org: org, scope: scope} = socket.assigns

    case SSO.verify_domain(org, scope) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(config: config)
         |> put_flash(:info, gettext("Domain verified."))}

      {:error, :not_found} ->
        {:noreply,
         put_flash(socket, :error, gettext("Configure SSO before verifying the domain."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not verify the domain."))}
    end
  end

  def handle_event("toggle_enabled", _params, socket) do
    %{org: org, scope: scope, config: config} = socket.assigns
    enable? = !(config && config.enabled)

    case SSO.enable_sso(org, scope, enable?) do
      {:ok, updated} ->
        msg = if updated.enabled, do: gettext("SSO enabled."), else: gettext("SSO disabled.")

        {:noreply,
         socket
         |> assign(config: updated)
         |> put_flash(:info, msg)}

      {:error, :domain_not_verified} ->
        {:noreply, put_flash(socket, :error, gettext("Verify the domain before enabling SSO."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not change SSO status."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load(socket, org, scope) do
    config = SSO.get_config(org)

    assign(socket,
      page_title: gettext("Single sign-on"),
      org: org,
      scope: scope,
      config: config,
      selected_protocol: (config && config.protocol) || :oidc,
      form_errors: %{}
    )
  end

  defp traverse(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp field_errors(errors, field), do: Map.get(errors, field, [])

  defp secret_set?(nil), do: false
  defp secret_set?(""), do: false
  defp secret_set?(value) when is_binary(value), do: true
  defp secret_set?(_), do: false

  # ---------------------------------------------------------------------------
  # Field component — one reusable label/input/error block so the OIDC and SAML
  # field scaffolding is not duplicated per-field in the template.
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil
  attr :input_class, :string, default: "input input-bordered w-full font-sans"
  attr :errors, :list, default: []
  attr :rest, :global, include: ~w(rows)

  defp sso_field(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label" for={@id}>
        <span class="label-text font-sans font-semibold">{@label}</span>
        <span :if={@hint} class="label-text-alt font-sans text-base-content/50">{@hint}</span>
      </label>
      <textarea
        :if={@type == "textarea"}
        id={@id}
        name={@name}
        placeholder={@placeholder}
        class={[@input_class, @errors != [] && "textarea-error"]}
        {@rest}
      >{@value}</textarea>
      <input
        :if={@type != "textarea"}
        id={@id}
        type={@type}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={[@input_class, @errors != [] && "input-error"]}
        {@rest}
      />
      <p :for={err <- @errors} class="mt-1 font-sans text-xs text-error">{err}</p>
    </div>
    """
  end
end
