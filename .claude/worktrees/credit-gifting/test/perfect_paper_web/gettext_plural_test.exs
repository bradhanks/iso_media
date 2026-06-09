defmodule PerfectPaperWeb.GettextPluralTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.GettextPlural

  test "hyphenated locales use their base language's plural rules" do
    for {variant, base} <- [{"en-GB", "en"}, {"fr-CA", "fr"}, {"es-MX", "es"}] do
      assert GettextPlural.nplurals(variant) == GettextPlural.nplurals(base)
      assert GettextPlural.plural(variant, 1) == GettextPlural.plural(base, 1)
      assert GettextPlural.plural(variant, 2) == GettextPlural.plural(base, 2)
    end
  end

  test "non-hyphenated locales pass through unchanged" do
    assert GettextPlural.nplurals("de") == Gettext.Plural.nplurals("de")
    assert GettextPlural.plural("de", 5) == Gettext.Plural.plural("de", 5)
  end

  test "ngettext does not raise for a hyphenated locale" do
    Gettext.put_locale(PerfectPaperWeb.Gettext, "en-GB")
    assert is_binary(Gettext.dngettext(PerfectPaperWeb.Gettext, "errors", "one", "many", 2))
  end
end
