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
end
