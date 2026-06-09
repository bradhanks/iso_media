defmodule PerfectPaperWeb.LocaleCatalogTest do
  @moduledoc """
  Automated quality gates for the translation catalogs. These don't judge
  translation *quality* (that needs native review) — they catch the mechanical
  failures machine drafts are prone to: missing coverage, broken `%{}`
  placeholders, and a locale that doesn't actually change the rendered page.
  """
  use PerfectPaperWeb.ConnCase, async: true

  @gettext_root Path.join([File.cwd!(), "priv", "gettext"])
  @locales PerfectPaper.Localization.codes()
  @placeholder ~r/%\{[^}]+\}/

  defp po_path(locale), do: Path.join([@gettext_root, locale, "LC_MESSAGES", "default.po"])
  defp placeholders(text), do: @placeholder |> Regex.scan(text) |> List.flatten() |> Enum.sort()

  describe "coverage" do
    test "every non-default locale catalog is fully translated" do
      for locale <- @locales, locale != "en" do
        %Expo.Messages{messages: messages} = Expo.PO.parse_file!(po_path(locale))

        untranslated =
          messages
          |> Enum.filter(&match?(%Expo.Message.Singular{}, &1))
          |> Enum.reject(fn m -> m.msgid == [""] end)
          |> Enum.filter(fn m -> IO.iodata_to_binary(m.msgstr) == "" end)
          |> Enum.map(fn m -> IO.iodata_to_binary(m.msgid) end)

        assert untranslated == [],
               "#{locale}: #{length(untranslated)} untranslated entries, e.g. #{inspect(Enum.take(untranslated, 3))}"
      end
    end
  end

  describe "placeholder integrity" do
    test "each translation preserves the msgid's %{...} placeholders" do
      for locale <- @locales, locale != "en" do
        %Expo.Messages{messages: messages} = Expo.PO.parse_file!(po_path(locale))

        mismatches =
          messages
          |> Enum.filter(&match?(%Expo.Message.Singular{}, &1))
          |> Enum.reject(fn m -> m.msgid == [""] end)
          |> Enum.map(fn m -> {IO.iodata_to_binary(m.msgid), IO.iodata_to_binary(m.msgstr)} end)
          |> Enum.reject(fn {_id, str} -> str == "" end)
          |> Enum.filter(fn {id, str} -> placeholders(id) != placeholders(str) end)
          |> Enum.map(fn {id, _str} -> id end)

        assert mismatches == [],
               "#{locale}: #{length(mismatches)} entries dropped/changed a %{} placeholder, e.g. #{inspect(Enum.take(mismatches, 3))}"
      end
    end
  end

  describe "rendering" do
    test "each locale changes the home page away from English", %{conn: conn} do
      english = conn |> get(~p"/") |> html_response(200)

      for locale <- @locales, locale not in ["en", "en-GB"] do
        localized =
          conn
          |> Plug.Conn.put_req_header("accept-language", locale)
          |> get(~p"/")
          |> html_response(200)

        refute localized == english,
               "#{locale}: home page is byte-identical to English — locale not applied or catalog empty"
      end
    end
  end
end
