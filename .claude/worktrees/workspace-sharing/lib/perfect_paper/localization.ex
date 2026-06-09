defmodule PerfectPaper.Localization do
  @moduledoc """
  Locale configuration and resolution — the single source of truth for which
  languages PerfectPaper supports and how a visitor's locale is chosen.

  This is config-as-code (like `Credits.Tier` / `Billing.Prices`): a pure module
  with no `Repo`/IO. It drives BOTH localization mechanisms — Gettext for static
  UI text and the LLM language directive for generated AI feedback — so they
  always agree on one locale.
  """

  @default_locale "en"

  # Display order. `base` is the language a variant falls back to.
  @locales [
    %{code: "en", language: "English", native_name: "English", base: "en"},
    %{code: "en-GB", language: "English (UK)", native_name: "English (UK)", base: "en"},
    %{code: "de", language: "German", native_name: "Deutsch", base: "de"},
    %{code: "fr", language: "French", native_name: "Français", base: "fr"},
    %{code: "fr-CA", language: "French (Canada)", native_name: "Français (Canada)", base: "fr"},
    %{code: "es", language: "Spanish", native_name: "Español", base: "es"},
    %{
      code: "es-MX",
      language: "Spanish (Latin America)",
      native_name: "Español (Latinoamérica)",
      base: "es"
    },
    %{code: "nl", language: "Dutch", native_name: "Nederlands", base: "nl"},
    %{code: "it", language: "Italian", native_name: "Italiano", base: "it"},
    %{code: "hi", language: "Hindi", native_name: "हिन्दी", base: "hi"},
    %{code: "ru", language: "Russian", native_name: "Русский", base: "ru"},
    %{code: "ro", language: "Romanian", native_name: "Română", base: "ro"}
  ]

  @codes Enum.map(@locales, & &1.code)

  @type locale :: %{
          code: String.t(),
          language: String.t(),
          native_name: String.t(),
          base: String.t()
        }

  @spec supported_locales() :: [locale()]
  def supported_locales, do: @locales

  @spec codes() :: [String.t()]
  def codes, do: @codes

  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @spec known?(String.t() | nil) :: boolean()
  def known?(code), do: code in @codes

  @spec native_name(String.t()) :: String.t() | nil
  def native_name(code) do
    case find(code) do
      nil -> nil
      loc -> loc.native_name
    end
  end

  @spec base_of(String.t()) :: String.t()
  def base_of(code) do
    case find(code) do
      nil -> code
      loc -> loc.base
    end
  end

  @doc "Negotiates the best supported locale from an `Accept-Language` header."
  @spec negotiate(String.t() | nil) :: String.t()
  def negotiate(nil), do: @default_locale
  def negotiate(""), do: @default_locale

  def negotiate(header) when is_binary(header) do
    header
    |> parse_accept_language()
    |> Enum.find_value(@default_locale, &match_tag/1)
  end

  @doc """
  Resolves the effective locale. Logged-in user's locale is authoritative; an
  anonymous visitor falls back cookie → Accept-Language → default.
  """
  @spec resolve(keyword()) :: String.t()
  def resolve(opts) do
    user = opts[:user]
    cookie = opts[:cookie]

    cond do
      user && known?(user.locale) -> user.locale
      is_binary(cookie) && known?(cookie) -> cookie
      true -> negotiate(opts[:accept_language])
    end
  end

  @doc """
  The English instruction appended to the LLM system prompt so AI feedback is
  written in the user's language. `nil` for English (the source language) and for
  unknown codes — the model already writes English by default.
  """
  @spec language_directive(String.t() | nil) :: String.t() | nil
  def language_directive("en"), do: nil

  def language_directive(code) do
    if known?(code) do
      "Write all overall feedback and comments to the author in #{native_name(code)} " <>
        "(locale #{code}). Use natural, idiomatic phrasing a native speaker would use; " <>
        "do not translate technical terms that are conventionally left in English."
    end
  end

  # --- helpers ---

  defp find(code), do: Enum.find(@locales, &(&1.code == code))

  # "de-DE,de;q=0.9,en;q=0.8" -> ["de-DE", "de", "en"] ordered by descending q.
  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_tag, q} -> q end, :desc)
    |> Enum.map(fn {tag, _q} -> tag end)
  end

  defp parse_entry(entry) do
    case entry |> String.trim() |> String.split(";") do
      ["*" | _] -> nil
      [""] -> nil
      [tag] -> {tag, 1.0}
      [tag, qpart] -> {tag, parse_q(qpart)}
      _ -> nil
    end
  end

  defp parse_q("q=" <> value) do
    case Float.parse(value) do
      {q, _} -> q
      :error -> 0.0
    end
  end

  defp parse_q(_), do: 1.0

  # Match an Accept-Language tag to a supported code: exact (case-insensitive)
  # first, then the base language. The base branch resolves via the `base` field
  # (not list order) so it stays correct regardless of how @locales is ordered.
  defp match_tag(tag) do
    down = String.downcase(tag)
    lang = down |> String.split("-") |> hd()

    Enum.find(@codes, &(String.downcase(&1) == down)) || base_code_for(lang)
  end

  defp base_code_for(lang) do
    Enum.find_value(@locales, fn loc ->
      if loc.base == lang and loc.code == loc.base, do: loc.code
    end)
  end
end
