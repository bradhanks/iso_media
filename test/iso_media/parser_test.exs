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

  test "stamps source_offset and source_size on top-level and nested boxes" do
    # moov (size 24) { mvhd (size 8) ; free (size 8) } then a trailing free (size 8)
    inner = <<8::32, "mvhd", 8::32, "free">>
    moov = <<8 + byte_size(inner)::32, "moov", inner::binary>>
    bin = moov <> <<8::32, "free">>

    assert {:ok, [moov_box, free_box]} = Parser.parse(bin)

    assert moov_box.source_offset == 0
    assert moov_box.source_size == 24
    assert free_box.source_offset == 24
    assert free_box.source_size == 8

    [mvhd, inner_free] = moov_box.children
    assert mvhd.source_offset == 8
    assert mvhd.source_size == 8
    assert inner_free.source_offset == 16
    assert inner_free.source_size == 8
  end

  test "the :offset option stamps absolute source_offsets" do
    inner = <<8::32, "mvhd", 8::32, "free">>
    moov = <<8 + byte_size(inner)::32, "moov", inner::binary>>

    assert {:ok, [moov_box]} = Parser.parse(moov, offset: 100)
    assert moov_box.source_offset == 100
    [mvhd, free] = moov_box.children
    assert mvhd.source_offset == 108
    assert free.source_offset == 116
  end

  describe "binary pinning" do
    # `:binary.referenced_byte_size/1` returns the size of the underlying refc
    # binary a sub-binary points into, or the binary's own size if it is a
    # standalone heap binary. A retained sub-binary of a large source therefore
    # reports the *source* size; a copied field reports a small size — its exact
    # value is OTP-internal (heap-binary accounting differs across OTP releases),
    # so we assert only that it is far below the source size, never equal to it.

    test "parsed box `type` does not pin the source binary" do
      # A >64-byte payload forces `source` to be an off-heap refc binary, so a
      # naive sub-binary `type` would pin all ~500 bytes of it.
      big = :binary.copy(<<0>>, 500)
      source = <<8 + byte_size(big)::32, "mdat", big::binary>>
      assert :binary.referenced_byte_size(source) > 64

      assert {:ok, [box]} = Parser.parse(source)
      assert box.type == "mdat"
      assert :binary.referenced_byte_size(box.type) < byte_size(source)
    end

    test "parsed box `uuid` does not pin the source binary" do
      uuid = :binary.copy(<<1>>, 16)
      big = :binary.copy(<<0>>, 500)
      source = <<8 + 16 + byte_size(big)::32, "uuid", uuid::binary, big::binary>>

      assert {:ok, [box]} = Parser.parse(source)
      assert box.uuid == uuid
      assert :binary.referenced_byte_size(box.uuid) < byte_size(source)
    end

    test "copying preserves the byte-exact round-trip" do
      big = :binary.copy(<<0>>, 500)
      source = <<8 + byte_size(big)::32, "mdat", big::binary>>
      assert {:ok, boxes} = Parser.parse(source)
      assert ISOMedia.serialize(boxes) == source
    end
  end
end
