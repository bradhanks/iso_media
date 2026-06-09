defmodule PerfectPaperWeb.GettextLocalesTest do
  use ExUnit.Case, async: true

  test "all supported locales have catalogs registered with Gettext" do
    known = Gettext.known_locales(PerfectPaperWeb.Gettext)

    for %{code: code} <- PerfectPaper.Localization.supported_locales() do
      assert code in known, "missing gettext catalog for #{code}"
    end
  end
end
