defmodule PerfectPaper.Security.UnicodeSanitizerTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Security.UnicodeSanitizer

  # Zero-width space (U+200B) used as 0-bit in ZW binary encoding
  @zw_space "\u200B"
  # Zero-width non-joiner (U+200C) used as 1-bit in ZW binary encoding
  @zw_nj "\u200C"
  # Unicode Tag 'R' (U+E0052) — Tags block starts at U+E0000
  @tag_r "\u{E0052}"

  describe "scan/1" do
    test "returns :clean for plain ASCII" do
      assert {:clean, "hello world"} = UnicodeSanitizer.scan("hello world")
    end

    test "returns :clean for normal Unicode (emoji, accents)" do
      assert {:clean, _} = UnicodeSanitizer.scan("Héllo wörld 🎉")
    end

    test "detects zero-width binary encoding characters" do
      payload = "normal text" <> @zw_space <> @zw_nj <> @zw_space <> "more text"
      assert {:injection_found, cats} = UnicodeSanitizer.scan(payload)
      assert :zero_width in cats
    end

    test "detects Unicode Tags block characters" do
      payload = "Before" <> @tag_r <> "After"
      assert {:injection_found, cats} = UnicodeSanitizer.scan(payload)
      assert :unicode_tags in cats
    end

    test "detects both schemes when both present" do
      payload = @zw_space <> @tag_r
      assert {:injection_found, cats} = UnicodeSanitizer.scan(payload)
      assert :zero_width in cats
      assert :unicode_tags in cats
    end

    test "returns :clean for non-binary values" do
      assert {:clean, 42} = UnicodeSanitizer.scan(42)
      assert {:clean, nil} = UnicodeSanitizer.scan(nil)
    end
  end

  describe "contains_injection?/1" do
    test "returns false for clean strings" do
      refute UnicodeSanitizer.contains_injection?("clean text")
    end

    test "returns true for zero-width encoded strings" do
      assert UnicodeSanitizer.contains_injection?("text" <> @zw_space)
    end

    test "returns true for Unicode Tags strings" do
      assert UnicodeSanitizer.contains_injection?("text" <> @tag_r)
    end

    test "returns false for non-binary input" do
      refute UnicodeSanitizer.contains_injection?(nil)
      refute UnicodeSanitizer.contains_injection?(42)
    end
  end

  describe "sanitize/1" do
    test "removes zero-width space" do
      assert UnicodeSanitizer.sanitize("a" <> @zw_space <> "b") == "ab"
    end

    test "removes zero-width non-joiner" do
      assert UnicodeSanitizer.sanitize("a" <> @zw_nj <> "b") == "ab"
    end

    test "removes Unicode Tags characters" do
      assert UnicodeSanitizer.sanitize("a" <> @tag_r <> "b") == "ab"
    end

    test "removes U+FEFF (BOM / zero-width no-break space)" do
      assert UnicodeSanitizer.sanitize("\uFEFFhello") == "hello"
    end

    test "removes bidi control characters (Trojan Source)" do
      # U+202E Right-To-Left Override
      assert UnicodeSanitizer.sanitize("a\u202Eb") == "ab"
      # U+202A Left-To-Right Embedding
      assert UnicodeSanitizer.sanitize("a\u202Ab") == "ab"
    end

    test "preserves legitimate Unicode content" do
      assert UnicodeSanitizer.sanitize("Héllo wörld") == "Héllo wörld"
      assert UnicodeSanitizer.sanitize("日本語") == "日本語"
      assert UnicodeSanitizer.sanitize("emoji 🎉") == "emoji 🎉"
    end

    test "strips a full hidden ZW-binary payload" do
      visible = "What is the capital of France?"
      hidden_bits = String.duplicate(@zw_space, 96)
      combined = String.slice(visible, 0, 5) <> hidden_bits <> String.slice(visible, 5..-1//1)

      result = UnicodeSanitizer.sanitize(combined)
      assert result == visible
      refute UnicodeSanitizer.contains_injection?(result)
    end

    test "passes through non-binary values unchanged" do
      assert UnicodeSanitizer.sanitize(42) == 42
      assert UnicodeSanitizer.sanitize(nil) == nil
      assert UnicodeSanitizer.sanitize([:a, :b]) == [:a, :b]
    end
  end

  describe "sanitize_params/1" do
    test "sanitizes string values in a flat map" do
      params = %{"name" => "Alice" <> @zw_space, "age" => "30"}
      result = UnicodeSanitizer.sanitize_params(params)
      assert result["name"] == "Alice"
      assert result["age"] == "30"
    end

    test "sanitizes nested maps" do
      params = %{"user" => %{"bio" => "Hello" <> @tag_r <> "World"}}
      result = UnicodeSanitizer.sanitize_params(params)
      assert result["user"]["bio"] == "HelloWorld"
    end

    test "sanitizes values in lists" do
      params = %{"tags" => ["clean", "inject" <> @zw_space]}
      result = UnicodeSanitizer.sanitize_params(params)
      assert result["tags"] == ["clean", "inject"]
    end

    test "passes through non-string values" do
      params = %{"count" => 5, "flag" => true, "nothing" => nil}
      assert UnicodeSanitizer.sanitize_params(params) == params
    end
  end

  describe "scan_params/1" do
    test "returns empty list for clean params" do
      assert [] = UnicodeSanitizer.scan_params(%{"name" => "Alice", "age" => "30"})
    end

    test "returns findings for injected params" do
      params = %{"bio" => "text" <> @zw_space}
      findings = UnicodeSanitizer.scan_params(params)
      assert [{["bio"], cats}] = findings
      assert :zero_width in cats
    end

    test "reports nested path correctly" do
      params = %{"user" => %{"notes" => "x" <> @tag_r}}
      findings = UnicodeSanitizer.scan_params(params)
      assert [{["user", "notes"], cats}] = findings
      assert :unicode_tags in cats
    end

    test "reports multiple injections across params" do
      params = %{"a" => @zw_space, "b" => @tag_r}
      findings = UnicodeSanitizer.scan_params(params)
      assert length(findings) == 2
    end
  end

  describe "validate_no_hidden_unicode/2" do
    test "adds no error for clean values" do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> UnicodeSanitizer.validate_no_hidden_unicode([:name])

      assert changeset.valid?
    end

    test "adds error for zero-width injection" do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{name: "Alice" <> @zw_space}, [:name])
        |> UnicodeSanitizer.validate_no_hidden_unicode([:name])

      refute changeset.valid?
      assert {"contains disallowed hidden Unicode characters", []} = changeset.errors[:name]
    end

    test "adds error for Unicode Tags injection" do
      changeset =
        {%{}, %{description: :string}}
        |> Ecto.Changeset.cast(%{description: "Hello" <> @tag_r}, [:description])
        |> UnicodeSanitizer.validate_no_hidden_unicode([:description])

      refute changeset.valid?

      assert {"contains disallowed hidden Unicode characters", []} =
               changeset.errors[:description]
    end

    test "ignores fields not in the field list" do
      changeset =
        {%{}, %{name: :string, bio: :string}}
        |> Ecto.Changeset.cast(%{name: "Alice", bio: "x" <> @zw_space}, [:name, :bio])
        |> UnicodeSanitizer.validate_no_hidden_unicode([:name])

      assert changeset.valid?
    end

    test "ignores unchanged fields" do
      changeset =
        {%{name: "Alice" <> @zw_space}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> UnicodeSanitizer.validate_no_hidden_unicode([:name])

      assert changeset.valid?
    end
  end
end
