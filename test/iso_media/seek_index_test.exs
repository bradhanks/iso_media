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

  describe "stream_range/4" do
    test "streamed bytes equal read_range for the same window, in chunk_size pieces" do
      boxes = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>, size_mode: :compact},
        %Box{type: "free", data: :binary.copy(<<7>>, 50), size_mode: :compact}
      ]

      idx = SeekIndex.build(boxes)
      bs = SeekIndex.content_length(idx)

      chunks = idx |> SeekIndex.stream_range(0, bs, 8) |> Enum.to_list()
      assert IO.iodata_to_binary(chunks) == SeekIndex.read_range(idx, 0, bs)
      # all chunks 8 bytes except possibly the last
      assert Enum.all?(Enum.drop(chunks, -1), &(byte_size(&1) == 8))
      assert length(chunks) == ceil(bs / 8)
    end

    @tag :tmp_dir
    test "streams a FileSlice-backed range lazily and correctly", %{tmp_dir: tmp} do
      # Build a file with a >64-byte mdat so lazy parse keeps it as a FileSlice.
      payload = :binary.copy(<<0xAB>>, 300)
      ftyp = <<12::32, "ftyp", "isom">>
      mdat = <<8 + byte_size(payload)::32, "mdat", payload::binary>>
      path = Path.join(tmp, "big.mp4")
      File.write!(path, ftyp <> mdat)

      {:ok, boxes} = ISOMedia.read(path, lazy: true, lazy_threshold: 64)
      assert Enum.any?(boxes, &match?(%Box{data: %ISOMedia.FileSlice{}}, &1))

      idx = SeekIndex.build(boxes)
      full = Serializer.serialize(boxes)

      # a mid-file sub-range that lands inside the FileSlice
      streamed = idx |> SeekIndex.stream_range(40, 120, 16) |> Enum.into(<<>>, & &1)
      assert streamed == :binary.part(full, 40, 120)
    end

    test "raises ArgumentError on negative / non-integer offset or length" do
      idx = SeekIndex.build([%Box{type: "free", data: <<1>>, size_mode: :compact}])
      assert_raise ArgumentError, fn -> SeekIndex.stream_range(idx, -1, 4) |> Enum.to_list() end
      assert_raise ArgumentError, fn -> SeekIndex.stream_range(idx, 0, -1) |> Enum.to_list() end
    end
  end
end
