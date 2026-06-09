defmodule ISOMedia.SeekIndexTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.{Box, SeekIndex, Serializer}

  describe "build/1 + content_length/1" do
    test "content_length equals byte_size(serialize(tree))" do
      tree = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}
      ]

      idx = SeekIndex.build(tree)
      assert SeekIndex.content_length(idx) == byte_size(Serializer.serialize(tree))
    end

    test "skips zero-size (empty) leaf payloads but counts their header" do
      # empty "free" leaf: 8-byte header, 0-byte payload.
      tree = [%Box{type: "free", data: <<>>, size_mode: :compact}]
      idx = SeekIndex.build(tree)
      assert SeekIndex.content_length(idx) == 8
    end

    test "accepts a single %Box{} as well as a list" do
      box = %Box{type: "free", data: <<1, 2>>, size_mode: :compact}
      assert SeekIndex.content_length(SeekIndex.build(box)) == 10
    end
  end
end
