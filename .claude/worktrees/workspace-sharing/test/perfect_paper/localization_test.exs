defmodule PerfectPaper.LocalizationTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Localization, as: L

  test "supported_locales lists 12 codes with native names" do
    codes = Enum.map(L.supported_locales(), & &1.code)

    assert L.default_locale() == "en"
    assert "en" in codes and "de" in codes and "fr-CA" in codes and "hi" in codes
    assert length(codes) == 12
    assert L.native_name("de") == "Deutsch"
    assert L.native_name("fr") == "Français"
  end

  test "known?/1 and base_of/1" do
    assert L.known?("es-MX")
    refute L.known?("zz")
    assert L.base_of("fr-CA") == "fr"
    assert L.base_of("de") == "de"
    assert L.base_of("unknown") == "unknown"
  end

  describe "negotiate/1 (Accept-Language)" do
    test "picks the highest-q supported tag" do
      assert L.negotiate("de-DE,de;q=0.9,en;q=0.8") == "de"
      assert L.negotiate("fr-CA,fr;q=0.9") == "fr-CA"
      assert L.negotiate("es-419,es;q=0.9") == "es"
    end

    test "falls back through base then default" do
      assert L.negotiate("pt-BR,pt;q=0.9") == "en"
      assert L.negotiate(nil) == "en"
      assert L.negotiate("") == "en"
    end
  end

  describe "resolve/1 (precedence)" do
    test "a logged-in user's locale wins" do
      assert L.resolve(user: %{locale: "ru"}, cookie: "de", accept_language: "fr") == "ru"
    end

    test "anonymous prefers cookie, then Accept-Language, then default" do
      assert L.resolve(user: nil, cookie: "nl", accept_language: "de") == "nl"
      assert L.resolve(user: nil, cookie: nil, accept_language: "de-DE") == "de"
      assert L.resolve(user: nil, cookie: "zz", accept_language: nil) == "en"
    end
  end

  describe "language_directive/1" do
    test "nil for English, instruction text for others" do
      assert L.language_directive("en") == nil
      directive = L.language_directive("de")
      assert directive =~ "Deutsch"
      assert directive =~ "de"
      assert L.language_directive("zz") == nil
    end
  end
end
