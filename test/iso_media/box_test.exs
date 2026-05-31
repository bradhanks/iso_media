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
end
