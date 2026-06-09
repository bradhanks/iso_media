defmodule PerfectPaperWeb.WorkspaceSwitcher do
  @moduledoc """
  Sidebar-header workspace switcher: shows the active workspace, drops down to
  switch (navigate to `/w/:id/reviews`), create a new workspace, or rename /
  delete an existing one. Encapsulates its own forms + events so the shared app
  shell needs no per-page wiring.

  ## In-place updates

  The component owns its display state — `@active` (the active workspace, for the
  trigger button) and `@ws_list` (the dropdown list) — seeded from the parent and
  refreshed from the DB after a mutation. It deliberately does NOT re-read the
  parent's (post-mutation stale) `workspaces` on ordinary re-renders; it only
  resyncs when the parent navigates to a different workspace (`current_workspace`
  identity changes). This lets rename / delete update in place with no page
  reload — the active workspace name is shown only here, so nothing else goes
  stale.

  Navigation happens only when it must: **create** switches into the new
  workspace, and **deleting the active workspace** lands on Personal (you can't
  remain on a deleted workspace's page). Rename and deleting a non-active
  workspace stay put.
  """
  use PerfectPaperWeb, :live_component

  alias PerfectPaper.Workspaces

  @impl true
  def update(assigns, socket) do
    parent_active = assigns.current_workspace
    user = assigns.current_user

    socket =
      socket
      |> assign(:current_user, user)
      |> assign_new(:creating, fn -> false end)
      |> assign_new(:editing_id, fn -> nil end)
      |> assign_new(:confirming_id, fn -> nil end)

    # Resync on first mount and whenever the page navigates to a different
    # workspace; otherwise keep our locally-managed list so an in-place
    # rename/delete isn't clobbered by a stale parent render. On resync the
    # parent's `workspaces` is fresh (its on_mount just ran), so reuse it rather
    # than issuing a redundant query.
    if resync?(socket, parent_active) do
      {:ok,
       socket
       |> assign(:active, parent_active)
       |> assign(:ws_list, assigns.workspaces)}
    else
      {:ok, socket}
    end
  end

  defp resync?(socket, parent_active),
    do: socket.assigns[:active] == nil or socket.assigns.active.id != parent_active.id

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply, assign(socket, creating: true, editing_id: nil, confirming_id: nil)}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, :creating, false)}
  end

  def handle_event("create_workspace", %{"name" => name}, socket) do
    case Workspaces.create_workspace(socket.assigns.current_user, %{name: name}) do
      {:ok, ws} -> {:noreply, push_navigate(socket, to: ~p"/w/#{ws.id}/reviews")}
      {:error, _changeset} -> {:noreply, assign(socket, :creating, false)}
    end
  end

  def handle_event("open_rename", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_id: id, confirming_id: nil, creating: false)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, :editing_id, nil)}
  end

  def handle_event("rename", %{"id" => id, "name" => name}, socket) do
    user = socket.assigns.current_user

    with %{} = ws <- find_workspace(socket, id),
         {:ok, renamed} <- Workspaces.rename_workspace(ws, user, name) do
      {:noreply,
       socket
       |> assign(:ws_list, Workspaces.list_workspaces(user))
       |> assign(
         :active,
         if(renamed.id == socket.assigns.active.id, do: renamed, else: socket.assigns.active)
       )
       |> assign(:editing_id, nil)}
    else
      _ -> {:noreply, assign(socket, :editing_id, nil)}
    end
  end

  def handle_event("open_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirming_id: id, editing_id: nil, creating: false)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirming_id, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %{} = ws <- find_workspace(socket, id),
         {:ok, _deleted} <- Workspaces.delete_workspace(ws, user) do
      if id == socket.assigns.active.id do
        # Deleting the active workspace — its page is gone, so leave for Personal.
        personal = Workspaces.personal_workspace(user)
        {:noreply, push_navigate(socket, to: ~p"/w/#{personal.id}/reviews")}
      else
        # A non-active workspace was removed — update the list in place, no reload.
        {:noreply,
         socket
         |> assign(:ws_list, Workspaces.list_workspaces(user))
         |> assign(:confirming_id, nil)}
      end
    else
      _ -> {:noreply, assign(socket, :confirming_id, nil)}
    end
  end

  defp find_workspace(socket, id), do: Enum.find(socket.assigns.ws_list, &(&1.id == id))

  @impl true
  def render(assigns) do
    ~H"""
    <div id="workspace-switcher" class="dropdown dropdown-bottom w-full">
      <button
        tabindex="0"
        class="flex w-full items-center gap-2.5 rounded-lg p-1.5 hover:bg-base-200 group-data-[collapsed=true]/shell:justify-center"
        aria-label={gettext("Switch workspace")}
      >
        <span class="grid size-7 shrink-0 place-items-center rounded-md bg-primary/10 font-sans text-sm font-semibold uppercase text-primary">
          {String.first(@active.name)}
        </span>
        <span class="group-data-[collapsed=true]/shell:hidden min-w-0 flex-1 truncate text-left font-display text-sm font-semibold">
          {@active.name}
        </span>
        <.icon
          name="hero-chevron-up-down"
          class="group-data-[collapsed=true]/shell:hidden size-4 shrink-0 text-base-content/40"
        />
      </button>

      <ul
        tabindex="0"
        class="dropdown-content z-50 mt-1 w-64 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <li :for={ws <- @ws_list} class="list-none">
          <%= cond do %>
            <% @editing_id == ws.id -> %>
              <form
                phx-submit="rename"
                phx-value-id={ws.id}
                phx-target={@myself}
                class="flex items-center gap-1.5 p-0.5"
              >
                <input
                  name="name"
                  value={ws.name}
                  autocomplete="off"
                  maxlength="120"
                  phx-mounted={JS.focus()}
                  class="input input-bordered input-sm w-full font-sans text-sm"
                />
                <button
                  type="submit"
                  class="btn btn-primary btn-sm btn-square"
                  aria-label={gettext("Save")}
                >
                  <.icon name="hero-check" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="cancel_rename"
                  phx-target={@myself}
                  class="btn btn-ghost btn-sm btn-square"
                  aria-label={gettext("Cancel")}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </form>
            <% @confirming_id == ws.id -> %>
              <div class="flex items-center gap-1.5 rounded-lg bg-base-200/60 px-2 py-1.5">
                <span class="min-w-0 flex-1 truncate font-sans text-xs text-base-content/70">
                  {gettext("Delete %{name}? Its reviews move to Personal.", name: ws.name)}
                </span>
                <button
                  type="button"
                  data-role={"confirm-delete-#{ws.id}"}
                  phx-click="delete"
                  phx-value-id={ws.id}
                  phx-target={@myself}
                  class="btn btn-error btn-xs"
                >
                  {gettext("Delete")}
                </button>
                <button
                  type="button"
                  phx-click="cancel_delete"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                  aria-label={gettext("Cancel")}
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
            <% true -> %>
              <div class="group/row flex items-center gap-0.5 rounded-lg hover:bg-base-200">
                <.link
                  navigate={~p"/w/#{ws.id}/reviews"}
                  class="flex min-w-0 flex-1 items-center gap-2 px-2.5 py-2 font-sans text-sm"
                >
                  <span class="min-w-0 flex-1 truncate">{ws.name}</span>
                  <.icon
                    :if={ws.id == @active.id}
                    name="hero-check"
                    class="size-4 shrink-0 text-primary"
                  />
                </.link>
                <button
                  type="button"
                  data-role={"rename-#{ws.id}"}
                  phx-click="open_rename"
                  phx-value-id={ws.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs btn-square opacity-0 group-hover/row:opacity-100 focus:opacity-100"
                  aria-label={gettext("Rename %{name}", name: ws.name)}
                >
                  <.icon name="hero-pencil" class="size-3.5 text-base-content/50" />
                </button>
                <button
                  :if={!ws.is_personal}
                  type="button"
                  data-role={"delete-#{ws.id}"}
                  phx-click="open_delete"
                  phx-value-id={ws.id}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs btn-square opacity-0 group-hover/row:opacity-100 focus:opacity-100"
                  aria-label={gettext("Delete %{name}", name: ws.name)}
                >
                  <.icon name="hero-trash" class="size-3.5 text-base-content/50" />
                </button>
              </div>
          <% end %>
        </li>

        <li class="mt-1 border-t border-base-300 pt-2"></li>

        <li :if={!@creating} class="list-none">
          <button
            type="button"
            data-role="open-create"
            phx-click="open_create"
            phx-target={@myself}
            class="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 font-sans text-sm hover:bg-base-200"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New workspace")}
          </button>
        </li>

        <li :if={@creating} class="list-none p-0.5">
          <form phx-submit="create_workspace" phx-target={@myself} class="flex items-center gap-1.5">
            <input
              name="name"
              autocomplete="off"
              maxlength="120"
              placeholder={gettext("Workspace name")}
              phx-mounted={JS.focus()}
              class="input input-bordered input-sm w-full font-sans text-sm"
            />
            <button
              type="submit"
              class="btn btn-primary btn-sm btn-square"
              aria-label={gettext("Create")}
            >
              <.icon name="hero-check" class="size-4" />
            </button>
          </form>
        </li>
      </ul>
    </div>
    """
  end
end
