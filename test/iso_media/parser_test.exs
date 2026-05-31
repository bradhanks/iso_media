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

  test "recurses into a known container box" do
    # moov(size 24) { mvhd(size 8, empty) ; free(size 8, empty) }
    inner = <<8::32, "mvhd", 8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "moov", inner::binary>>

    assert {:ok, [moov]} = Parser.parse(bin)
    assert moov.type == "moov"
    assert moov.data == nil
    assert [%{type: "mvhd"}, %{type: "free"}] = moov.children
  end

  test "parses a 64-bit largesize box" do
    # size field == 1, largesize == 20 (16 header + 4 payload)
    bin = <<1::32, "mdat", 20::64, 9, 9, 9, 9>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "mdat", data: <<9, 9, 9, 9>>, size_mode: :large} = box
  end

  test "parses a size-0 box that runs to end of input" do
    bin = <<0::32, "mdat", 7, 7, 7>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert %Box{type: "mdat", data: <<7, 7, 7>>, size_mode: :eof} = box
  end

  test "parses a uuid box, splitting out the 16-byte extended type" do
    uuid = <<0::128>>
    # size = 8 header + 16 uuid + 3 payload = 27
    bin = <<27::32, "uuid", uuid::binary, 1, 2, 3>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert box.type == "uuid"
    assert box.uuid == uuid
    assert box.data == <<1, 2, 3>>
  end

  test "unknown box stays a leaf without :heuristic" do
    inner = <<8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "XBOX", inner::binary>>
    assert {:ok, [box]} = Parser.parse(bin)
    assert box.data == inner
    assert box.children == []
  end

  test "unknown box recurses with :heuristic enabled" do
    inner = <<8::32, "free">>
    bin = <<8 + byte_size(inner)::32, "XBOX", inner::binary>>
    assert {:ok, [box]} = Parser.parse(bin, heuristic: true)
    assert box.data == nil
    assert [%{type: "free"}] = box.children
  end
end
