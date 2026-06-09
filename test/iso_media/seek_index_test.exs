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

  # --- generators: in-memory trees of leaf + container boxes (the {:bytes,_} path) ---
  defp leaf_type do
    gen all(
          <<a, b, c, d>> <- binary(length: 4),
          type = printable(<<a, b, c, d>>),
          not ISOMedia.Registry.container?(type)
        ) do
      type
    end
  end

  defp printable(<<a, b, c, d>>), do: <<az(a), az(b), az(c), az(d)>>
  defp az(byte), do: 0x41 + rem(byte, 26)

  defp leaf_box do
    gen all(type <- leaf_type(), data <- binary(max_length: 40)) do
      %Box{type: type, data: data, size_mode: :compact}
    end
  end

  defp container_box do
    gen all(type <- leaf_type(), kids <- list_of(leaf_box(), max_length: 3)) do
      %Box{type: type, data: nil, children: kids, size_mode: :compact}
    end
  end

  defp tree_gen, do: list_of(one_of([leaf_box(), container_box()]), min_length: 1, max_length: 6)

  # The defining invariant: read_range == binary_part(serialize, clamped window).
  defp assert_oracle(boxes, offset, length) do
    idx = SeekIndex.build(boxes)
    full = Serializer.serialize(boxes)
    bs = byte_size(full)
    start = min(offset, bs)
    finish = min(offset + length, bs)
    assert SeekIndex.read_range(idx, offset, length) == :binary.part(full, start, finish - start)
  end

  describe "read_range/3 oracle" do
    property "read_range matches binary_part of serialize for any range (generated trees)" do
      check all(boxes <- tree_gen(), offset <- integer(0..400), length <- integer(0..400)) do
        assert_oracle(boxes, offset, length)
      end
    end

    test "full-range read reproduces serialize/1 exactly" do
      boxes = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: <<1, 2, 3, 4, 5, 6>>, size_mode: :compact}
      ]

      idx = SeekIndex.build(boxes)

      assert SeekIndex.read_range(idx, 0, SeekIndex.content_length(idx)) ==
               Serializer.serialize(boxes)
    end

    test "zero-length, past-EOF, and over-long ranges follow HTTP-Range semantics" do
      boxes = [%Box{type: "free", data: <<1, 2, 3, 4>>, size_mode: :compact}]
      idx = SeekIndex.build(boxes)
      bs = SeekIndex.content_length(idx)

      assert SeekIndex.read_range(idx, 0, 0) == <<>>
      assert SeekIndex.read_range(idx, bs, 10) == <<>>
      assert SeekIndex.read_range(idx, bs + 100, 10) == <<>>
      # over-long: returns the available tail, no error
      assert SeekIndex.read_range(idx, 0, bs + 100) == Serializer.serialize(boxes)
    end

    test "raises ArgumentError on negative / non-integer offset or length" do
      idx = SeekIndex.build([%Box{type: "free", data: <<1>>, size_mode: :compact}])
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, -1, 4) end
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, 0, -4) end
      assert_raise ArgumentError, fn -> SeekIndex.read_range(idx, 1.5, 4) end
    end
  end
end
