defmodule PerfectPaperWeb.LocaleSwitcher do
  @moduledoc """
  Globe-icon language switcher. Reads the current locale from Gettext (set by the
  FetchLocale plug / :load_locale on_mount) and offers the supported languages by
  native name. Each option is a submit button on one form posting to `/locale`.
  """
  use PerfectPaperWeb, :html

  alias PerfectPaper.Localization

  attr :return_to, :string, default: nil, doc: "optional same-origin path to return to"

  def switcher(assigns) do
    assigns =
      assigns
      |> assign(:current, Gettext.get_locale(PerfectPaperWeb.Gettext))
      |> assign(:locales, Localization.supported_locales())

    ~H"""
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        type="button"
        class="btn btn-ghost btn-sm gap-1.5"
        aria-label={gettext("Change language")}
      >
        <.icon name="hero-language" class="size-4" />
        <span class="font-sans text-xs font-semibold uppercase">{short(@current)}</span>
      </button>
      <div
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <.form for={%{}} action={~p"/locale"} method="post">
          <input :if={@return_to} type="hidden" name="return_to" value={@return_to} />
          <button
            :for={loc <- @locales}
            type="submit"
            name="locale"
            value={loc.code}
            class={[
              "flex w-full items-center justify-between rounded-lg px-3 py-2 text-left font-sans text-sm hover:bg-base-200",
              loc.code == @current && "font-semibold text-primary"
            ]}
          >
            {loc.native_name}
            <.icon :if={loc.code == @current} name="hero-check" class="size-4" />
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp short(code), do: code |> to_string() |> String.split("-") |> hd() |> String.upcase()
end
