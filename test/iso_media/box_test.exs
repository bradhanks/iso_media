defmodule ISOMedia.BoxTest do
  use ExUnit.Case
  alias ISOMedia.Box

  test "defaults: a fresh box is a compact container with no children" do
    box = %Box{type: "moov"}
    assert box.type == "moov"
    assert box.data == nil
    assert box.children == []
    assert box.uuid == nil
    assert box.size_mode == :compact
  end

  test "source_offset and source_size default to nil" do
    box = %Box{type: "moov"}
    assert box.source_offset == nil
    assert box.source_size == nil
  end

  test "container?/1 and leaf?/1 distinguish by data" do
    container = %Box{type: "moov", data: nil, children: []}
    leaf = %Box{type: "free", data: <<0, 0>>}
    assert Box.container?(container)
    refute Box.leaf?(container)
    assert Box.leaf?(leaf)
    refute Box.container?(leaf)
  end

  describe "navigation" do
    setup do
      tree = [
        %Box{type: "ftyp", data: <<0>>},
        %Box{
          type: "moov",
          children: [
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<1>>}]},
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<2>>}]}
          ]
        }
      ]

      %{tree: tree}
    end

    test "find/2 returns the first match for a type-path", %{tree: tree} do
      assert %Box{type: "tkhd", data: <<1>>} = Box.find(tree, ~w(moov trak tkhd))
    end

    test "find/2 returns nil when nothing matches", %{tree: tree} do
      assert Box.find(tree, ~w(moov nope)) == nil
    end

    test "find_all/2 returns every match", %{tree: tree} do
      assert [%Box{data: <<1>>}, %Box{data: <<2>>}] = Box.find_all(tree, ~w(moov trak tkhd))
    end

    test "find_all/2 with a single-element path matches top level", %{tree: tree} do
      assert [%Box{type: "ftyp"}] = Box.find_all(tree, ~w(ftyp))
    end
  end

  describe "editing" do
    setup do
      tree = [
        %Box{
          type: "moov",
          children: [
            %Box{type: "trak", children: [%Box{type: "tkhd", data: <<1>>}]},
            %Box{type: "udta", children: []}
          ]
        }
      ]

      %{tree: tree}
    end

    test "update/3 applies fun to all matches", %{tree: tree} do
      updated = Box.update(tree, ~w(moov trak tkhd), &Box.replace_data(&1, <<9>>))
      assert %Box{data: <<9>>} = Box.find(updated, ~w(moov trak tkhd))
    end

    test "remove/2 cuts matching boxes out", %{tree: tree} do
      pruned = Box.remove(tree, ~w(moov udta))
      assert Box.find(pruned, ~w(moov udta)) == nil
      assert Box.find(pruned, ~w(moov trak)) != nil
    end

    test "insert/4 splices a box into the container at the path", %{tree: tree} do
      name = %Box{type: "name", data: "hi"}
      out = Box.insert(tree, ~w(moov udta), name, :end)
      assert [%Box{type: "name", data: "hi"}] = Box.find(out, ~w(moov udta)).children
    end

    test "insert/4 at :start prepends", %{tree: tree} do
      box = %Box{type: "free", data: ""}
      out = Box.insert(tree, ~w(moov), box, :start)
      assert %Box{type: "free"} = hd(Box.find(out, ~w(moov)).children)
    end

    test "insert/4 raises when the target path is a leaf", %{tree: tree} do
      assert_raise ArgumentError, fn ->
        Box.insert(tree, ~w(moov trak tkhd), %Box{type: "free", data: ""}, :end)
      end
    end

    test "replace_data/2 turns a box into a leaf with new bytes" do
      box = %Box{type: "moov", children: [%Box{type: "x"}]}
      assert %Box{data: <<7>>, children: []} = Box.replace_data(box, <<7>>)
    end
  end

  describe "read_data/1" do
    test "returns the binary for an in-memory leaf" do
      assert Box.read_data(%Box{type: "free", data: <<1, 2, 3>>}) == <<1, 2, 3>>
    end

    test "returns nil for a container" do
      assert Box.read_data(%Box{type: "moov", data: nil, children: []}) == nil
    end

    test "reads the bytes for a FileSlice leaf" do
      path = Path.join(System.tmp_dir!(), "iso_box_rd_#{System.unique_integer([:positive])}.bin")
      File.write!(path, <<9, 8, 7, 6, 5>>)
      on_exit(fn -> File.rm(path) end)
      box = %Box{type: "mdat", data: %ISOMedia.FileSlice{path: path, offset: 1, length: 3}}
      assert Box.read_data(box) == <<8, 7, 6>>
    end
  end

  describe "leaf/3" do
    test "builds a leaf box from a binary payload with defaults" do
      box = Box.leaf("free", <<0, 0>>)
      assert box.type == "free"
      assert box.data == <<0, 0>>
      assert box.children == []
      assert box.size_mode == :compact
      assert box.uuid == nil
      assert Box.leaf?(box)
    end

    test "accepts a FileSlice payload" do
      fs = %ISOMedia.FileSlice{path: "x", offset: 0, length: 4}
      box = Box.leaf("mdat", fs)
      assert box.data == fs
      assert Box.leaf?(box)
    end

    test "opts set uuid and size_mode" do
      box = Box.leaf("uuid", <<1, 2>>, uuid: <<0::128>>, size_mode: :large)
      assert box.uuid == <<0::128>>
      assert box.size_mode == :large
    end
  end

  describe "container/3" do
    test "builds an empty container by default" do
      box = Box.container("moov")
      assert box.type == "moov"
      assert box.data == nil
      assert box.children == []
      assert box.size_mode == :compact
      assert Box.container?(box)
    end

    test "builds a container from child boxes" do
      child = Box.leaf("free", <<>>)
      box = Box.container("moov", [child])
      assert box.children == [child]
      assert Box.container?(box)
    end

    test "opts set uuid and size_mode" do
      box = Box.container("moov", [], size_mode: :large)
      assert box.size_mode == :large
    end
  end

  describe "new/2" do
    test "a binary payload makes a leaf" do
      assert Box.new("free", <<1>>) == Box.leaf("free", <<1>>)
      assert Box.leaf?(Box.new("free", <<1>>))
    end

    test "a FileSlice makes a leaf" do
      fs = %ISOMedia.FileSlice{path: "x", offset: 0, length: 1}
      assert Box.leaf?(Box.new("mdat", fs))
    end

    test "a list of boxes makes a container" do
      child = Box.leaf("free", <<>>)
      assert Box.new("moov", [child]) == Box.container("moov", [child])
      assert Box.container?(Box.new("moov", [child]))
    end

    test "an empty list makes an empty container" do
      assert Box.container?(Box.new("moov", []))
    end

    test "raises on an ambiguous list (e.g. a segment list), directing to leaf/container" do
      assert_raise ArgumentError, ~r/leaf\/3 or .*container\/3/, fn ->
        Box.new("mdat", [<<1, 2>>, <<3, 4>>])
      end
    end
  end

  describe "sibling navigation" do
    setup do
      boxes = [
        Box.leaf("ftyp", <<>>),
        Box.container("moov", [Box.leaf("mvhd", <<>>), Box.leaf("trak", <<1>>), Box.leaf("trak", <<2>>)]),
        Box.leaf("mdat", <<>>)
      ]

      {:ok, boxes: boxes}
    end

    test "child/2 returns the first sibling of a type, or nil", %{boxes: boxes} do
      assert Box.child(boxes, "moov").type == "moov"
      assert Box.child(boxes, "free") == nil
    end

    test "children/2 returns all siblings of a type, in order", %{boxes: boxes} do
      moov = Box.child(boxes, "moov")
      assert Box.children(moov.children, "trak") |> Enum.map(& &1.data) == [<<1>>, <<2>>]
      assert Box.children(boxes, "trak") == []
    end

    test "child!/3 raises with context when absent", %{boxes: boxes} do
      assert Box.child!(boxes, "moov").type == "moov"
      assert_raise ArgumentError, ~r/faststart: no moof box/, fn ->
        Box.child!(boxes, "moof", "faststart")
      end

      assert_raise ArgumentError, ~r/^no moof box/, fn -> Box.child!(boxes, "moof") end
    end

    test "insert_after/3 slots boxes after the first of a type (front if absent)", %{boxes: boxes} do
      moov = Box.child(boxes, "moov")
      new = Box.insert_after(moov.children, "mvhd", [Box.leaf("trak", <<9>>)])
      assert Enum.map(new, & &1.type) == ~w(mvhd trak trak trak)
      assert Enum.at(new, 1).data == <<9>>

      front = Box.insert_after([Box.leaf("a", <<>>)], "zz", [Box.leaf("b", <<>>)])
      assert Enum.map(front, & &1.type) == ~w(b a)
    end
  end

  describe "size encoding helpers" do
    test "size_mode_for_body picks :compact until the 32-bit size field overflows" do
      assert Box.size_mode_for_body(0) == :compact
      # total = 8 + body; the largest compact total is 0xFFFFFFFF.
      assert Box.size_mode_for_body(0xFFFFFFFF - 8) == :compact
      assert Box.size_mode_for_body(0xFFFFFFFF - 7) == :large
      assert Box.size_mode_for_body(0x1_0000_0000) == :large
    end

    test "header_base maps each size_mode to its header byte length" do
      assert Box.header_base(:compact) == 8
      assert Box.header_base(:large) == 16
      assert Box.header_base(:eof) == 8
    end
  end
end
