defmodule ISOMedia.CursorTest do
  use ExUnit.Case
  alias ISOMedia.{Box, Cursor}

  defp tree do
    trak = fn n -> Box.container("trak", [Box.leaf("tkhd", <<n>>)]) end

    [
      Box.leaf("ftyp", <<>>),
      Box.container("moov", [Box.leaf("mvhd", <<0>>), trak.(1), trak.(2)]),
      Box.leaf("mdat", <<>>)
    ]
  end

  test "at/2 focuses the Nth box of a type along a path" do
    c = Cursor.at(tree(), ["moov", {"trak", 1}, "tkhd"])
    assert Cursor.focus(c).type == "tkhd"
    assert Cursor.focus(c).data == <<2>>

    # bare type means the first match
    assert Cursor.at(tree(), ["moov", "trak", "tkhd"]) |> Cursor.focus() |> Map.get(:data) == <<1>>
  end

  test "at/2 returns nil for an unresolved path (composes with ||)" do
    assert Cursor.at(tree(), ["moov", {"trak", 9}, "tkhd"]) == nil
    assert Cursor.at(tree(), ["nope"]) == nil
    assert Cursor.at(tree(), ["moov", "trak", "missing"]) == nil
  end

  test "update/replace edit only the focused box; tree/1 rebuilds the rest verbatim" do
    rebuilt =
      tree()
      |> Cursor.at(["moov", {"trak", 1}, "tkhd"])
      |> Cursor.update(fn b -> Box.replace_data(b, <<99>>) end)
      |> Cursor.tree()

    [ftyp, moov, mdat] = rebuilt
    [mvhd, trak0, trak1] = moov.children
    assert ftyp.type == "ftyp" and mdat.type == "mdat" and mvhd.data == <<0>>
    assert hd(trak0.children).data == <<1>>
    assert hd(trak1.children).data == <<99>>
  end

  test "up/1 walks to the parent and nil at the top level" do
    c = Cursor.at(tree(), ["moov", {"trak", 1}, "tkhd"])
    assert c |> Cursor.up() |> Cursor.focus() |> Map.get(:type) == "trak"
    assert c |> Cursor.up() |> Cursor.up() |> Cursor.focus() |> Map.get(:type) == "moov"
    assert tree() |> Cursor.at(["ftyp"]) |> Cursor.up() == nil
  end

  test "editing through a parent reached by up/1 rebuilds correctly" do
    rebuilt =
      tree()
      |> Cursor.at(["moov", {"trak", 0}, "tkhd"])
      |> Cursor.up()
      |> Cursor.update(fn trak -> %{trak | children: trak.children ++ [Box.leaf("edts", <<7>>)]} end)
      |> Cursor.tree()

    [_ftyp, moov, _mdat] = rebuilt
    [_mvhd, trak0, _trak1] = moov.children
    assert Enum.map(trak0.children, & &1.type) == ["tkhd", "edts"]
  end

  test "remove/1 drops exactly the focused box and returns the rebuilt tree" do
    pruned = tree() |> Cursor.at(["moov", {"trak", 0}]) |> Cursor.remove()
    [_ftyp, moov, _mdat] = pruned
    remaining = Box.children(moov.children, "trak")
    assert length(remaining) == 1
    assert hd(hd(remaining).children).data == <<2>>

    # removing a top-level box
    assert tree() |> Cursor.at(["mdat"]) |> Cursor.remove() |> Enum.map(& &1.type) == ~w(ftyp moov)
  end

  test "focus -> rebuild on a real file is byte-identical" do
    {:ok, boxes} = ISOMedia.parse(File.read!("test/fixtures/sample_av.mp4"))

    rebuilt =
      boxes
      |> Cursor.at(["moov", "mvhd"])
      |> Cursor.update(& &1)
      |> Cursor.tree()

    assert ISOMedia.serialize(rebuilt) == File.read!("test/fixtures/sample_av.mp4")
  end
end
