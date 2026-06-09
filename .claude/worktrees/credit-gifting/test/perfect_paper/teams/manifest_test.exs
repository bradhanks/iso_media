defmodule PerfectPaper.Teams.ManifestTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Teams.Manifest

  describe "manifest/0" do
    test "has bots with app id and personal scope" do
      m = Manifest.manifest()
      [bot] = m["bots"]

      assert bot["botId"] ==
               Application.get_env(
                 :perfect_paper,
                 :teams_app_id,
                 "00000000-0000-0000-0000-000000000000"
               )

      assert "personal" in bot["scopes"]
    end

    test "has icons keys for color and outline" do
      m = Manifest.manifest()
      assert m["icons"]["color"] == "color.png"
      assert m["icons"]["outline"] == "outline.png"
    end

    test "has required manifest fields" do
      m = Manifest.manifest()
      assert m["manifestVersion"] == "1.16"
      assert m["accentColor"] == "#7a2e4e"
      assert m["version"] == "1.0.0"
    end
  end

  describe "package/0" do
    test "returns a binary and contains manifest.json, color.png, outline.png" do
      zip_binary = Manifest.package()
      assert is_binary(zip_binary)

      {:ok, entries} = :zip.unzip(zip_binary, [:memory])
      filenames = Enum.map(entries, fn {name, _content} -> name end)

      assert ~c"manifest.json" in filenames
      assert ~c"color.png" in filenames
      assert ~c"outline.png" in filenames
    end

    test "manifest.json in the ZIP decodes to valid JSON with bots" do
      zip_binary = Manifest.package()
      {:ok, entries} = :zip.unzip(zip_binary, [:memory])
      {_, json_binary} = Enum.find(entries, fn {name, _} -> name == ~c"manifest.json" end)
      decoded = Jason.decode!(json_binary)
      assert is_list(decoded["bots"])
      assert length(decoded["bots"]) == 1
    end
  end
end
