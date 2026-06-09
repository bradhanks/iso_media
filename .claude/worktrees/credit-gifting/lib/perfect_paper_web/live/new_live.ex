defmodule PerfectPaperWeb.NewLive do
  @moduledoc """
  "New review" flow: a writer uploads a manuscript, which is stored via the
  Documents context and turned into a History session they can open.

  The web layer composes two context APIs here — `Documents` for the upload and
  `History` for the session — keeping the contexts themselves decoupled.
  """
  use PerfectPaperWeb, :live_view

  alias PerfectPaper.{Documents, History}

  @max_bytes 25_000_000
  @accept ~w(.docx)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      user_id = socket.assigns.current_scope.user.id
      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "user:#{user_id}")
    end

    socket =
      socket
      |> assign(page_title: gettext("New review"), error: nil, credits_low_warning: nil)
      |> allow_upload(:manuscript,
        accept: @accept,
        max_entries: 1,
        max_file_size: @max_bytes
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, error: nil)}

  def handle_event("cancel", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :manuscript, ref)}
  end

  def handle_event("submit", _params, socket) do
    user = socket.assigns.current_scope.user

    results =
      consume_uploaded_entries(socket, :manuscript, fn %{path: path}, entry ->
        content = File.read!(path)
        title = Path.rootname(entry.client_name)

        outcome =
          with {:ok, _level} <- History.intended_level(user.id),
               {:ok, document} <-
                 Documents.ingest(user, content, %{
                   filename: entry.client_name,
                   content_type: entry.client_type,
                   source_format: "docx"
                 }),
               {:ok, session} <-
                 History.begin_session(%{
                   user_id: user.id,
                   title: title,
                   document_id: document.id,
                   workspace_id: socket.assigns.current_workspace.id
                 }),
               {:ok, _job} <- Documents.start_conversion(document) do
            {:ok, session}
          end

        {:ok, outcome}
      end)

    case results do
      [{:ok, %History.Session{} = session}] ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Your review is ready."))
         |> push_navigate(to: ~p"/w/#{socket.assigns.current_workspace.id}/review/#{session.id}")}

      [{:error, :no_credits}] ->
        {:noreply,
         assign(socket,
           error:
             gettext(
               "You're out of credits. Earn free preview credits by inviting colleagues, or buy reviews."
             )
         )}

      [] ->
        {:noreply, assign(socket, error: gettext("Choose a manuscript to upload first."))}

      _ ->
        {:noreply,
         assign(socket, error: gettext("We couldn't process that file. Please try again."))}
    end
  end

  @impl true
  def handle_info({:credits_low, billing_period}, socket) do
    {:noreply, assign(socket, :credits_low_warning, billing_period)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Template components -------------------------------------------------------

  attr :title, :string, required: true
  slot :inner_block, required: true, doc: "the icon's inner SVG paths"

  defp reassure_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <svg
        class="size-[18px] text-primary"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        {render_slot(@inner_block)}
      </svg>
      <p class="mt-2 font-sans text-xs font-semibold leading-snug">{@title}</p>
    </div>
    """
  end

  # Template helpers ---------------------------------------------------------

  defp error_text(:too_large), do: gettext("That file is larger than 25 MB.")
  defp error_text(:not_accepted), do: gettext("Upload a .docx file.")
  defp error_text(:too_many_files), do: gettext("Upload one manuscript at a time.")
  defp error_text(_), do: gettext("There was a problem with that file.")
end
