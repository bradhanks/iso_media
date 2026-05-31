defmodule ISOMedia.ParserTest do
  use ExUnit.Case
  alias ISOMedia.{Box, Parser}

  test "parses a single compact leaf box" do
    # size=12 (8 header + 4 payload), type "free", payload <<1,2,3,4>>
    bin = <<12::32, "free", 1, 2, 3, 4>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "free", data: <<1, 2, 3, 4>>, children: [], size_mode: :compact} = box
  end

  test "parses a sequence of sibling boxes" do
    bin = <<8::32, "free", 9::32, "skip", 0>>
    assert {:ok, [a, b]} = Parser.parse(bin)
    assert %Box{type: "free", data: ""} = a
    assert %Box{type: "skip", data: <<0>>} = b
  end

  test "empty input parses to an empty list" do
    assert {:ok, []} = Parser.parse(<<>>)
  end
end
