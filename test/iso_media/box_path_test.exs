defmodule ISOMedia.BoxPathTest do
  use ExUnit.Case
  alias ISOMedia.{Box, BoxPath}

  defp tree do
    %Box{
      type: "moov",
      children: [
        %Box{type: "trak", children: [%Box{type: "tkhd", data: <<1>>}]},
        %Box{type: "udta", children: []}
      ]
    }
  end

  test "dig/2 navigates a single box by child-type path" do
    assert %Box{type: "tkhd", data: <<1>>} = BoxPath.dig(tree(), ~w(trak tkhd))
    assert BoxPath.dig(tree(), ~w(trak nope)) == nil
  end

  test "update_descendant/3 applies fun to the box at the path" do
    updated = BoxPath.update_descendant(tree(), ~w(trak tkhd), fn b -> %{b | data: <<9>>} end)
    assert BoxPath.dig(updated, ~w(trak tkhd)).data == <<9>>
  end

  test "update_descendant/3 with [] applies fun to the box itself" do
    assert BoxPath.update_descendant(%Box{type: "x"}, [], fn b -> %{b | type: "y"} end).type ==
             "y"
  end
end
