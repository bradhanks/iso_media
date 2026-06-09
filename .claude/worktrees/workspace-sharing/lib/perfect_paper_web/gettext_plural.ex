defmodule PerfectPaperWeb.GettextPlural do
  @moduledoc """
  Custom pluralizer for PerfectPaper that extends `Gettext.Plural` to support
  BCP 47 hyphenated locale codes (e.g. `en-GB`, `fr-CA`, `es-MX`).

  Gettext's default plural module handles `xx_YY` (underscore-separated) pairs
  by forwarding to the base language `xx`, but it does NOT handle `xx-YY`
  (hyphen-separated) BCP 47 codes. PerfectPaper uses BCP 47 codes throughout
  (see `PerfectPaper.Localization`), so we normalise them here: any tag
  containing a hyphen is forwarded to its base language tag before delegating
  to `Gettext.Plural`.

  Register this module globally so that both `mix gettext.merge` and the
  runtime backend agree on plural forms:

      # config/config.exs
      config :gettext, :plural_forms, PerfectPaperWeb.GettextPlural
  """

  @behaviour Gettext.Plural

  @impl Gettext.Plural
  @spec nplurals(String.t()) :: pos_integer()
  def nplurals(locale) do
    Gettext.Plural.nplurals(base(locale))
  end

  @impl Gettext.Plural
  @spec plural(String.t(), non_neg_integer()) :: non_neg_integer()
  def plural(locale, n) do
    Gettext.Plural.plural(base(locale), n)
  end

  # Strip the territory subtag from a BCP 47 hyphenated code so Gettext.Plural
  # can look up the base language's plural rules. Non-hyphenated codes pass
  # through unchanged.
  @spec base(String.t()) :: String.t()
  defp base(locale) do
    case String.split(locale, "-", parts: 2) do
      [lang, _territory] -> lang
      [lang] -> lang
    end
  end
end
