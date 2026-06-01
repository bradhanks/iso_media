defmodule ISOMedia.OffsetsTest do
  use ExUnit.Case
  alias ISOMedia.Box

  # --- helpers: build a parsed tree with a stco pointing into an mdat ---
  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  defp stco_data(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::32>>
    <<0, 0, 0, 0, length(offsets)::32, entries::binary>>
  end

  # Build ftyp + moov(stco) + mdat where stco points at chunk starts inside mdat.
  # Returns the parsed boxes. The mdat payload is `chunks` concatenated.
  defp build(chunks) do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # moov size is independent of offset *values* (fixed 32-bit entries), so build
    # once with zeros to learn its size, then with the real offsets.
    n = length(chunks)
    moov0 = container("moov", leaf("stco", stco_data(List.duplicate(0, n))))
    mdat_payload_start = byte_size(ftyp) + byte_size(moov0) + 8

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    moov = container("moov", leaf("stco", stco_data(offsets)))
    mdat = leaf("mdat", mdat_payload)
    {:ok, boxes} = ISOMedia.parse(ftyp <> moov <> mdat)
    %{boxes: boxes, offsets: offsets, chunks: chunks}
  end

  defp stco_offsets(boxes) do
    boxes
    |> ISOMedia.Box.find(~w(moov stco))
    |> ISOMedia.Boxes.ChunkOffset.decode()
    |> Map.fetch!(:offsets)
  end

  test "no-op: fixing an unmodified tree leaves offsets unchanged and serializes identically" do
    %{boxes: boxes} = build([<<1, 2>>, <<3, 4, 5>>])
    bin = ISOMedia.serialize(boxes)
    fixed = ISOMedia.fix_chunk_offsets(boxes)
    assert stco_offsets(fixed) == stco_offsets(boxes)
    assert ISOMedia.serialize(fixed) == bin
  end

  test "after inserting a free box before mdat, offsets shift by the free box size" do
    %{boxes: boxes, offsets: offsets} = build([<<1, 2>>, <<3, 4, 5>>])
    free = %Box{type: "free", data: <<0, 0, 0, 0>>}
    # free box total size = 8 + 4 = 12
    moved = List.insert_at(boxes, 1, free)
    fixed = ISOMedia.fix_chunk_offsets(moved)
    assert stco_offsets(fixed) == Enum.map(offsets, &(&1 + 12))
  end

  test "fixed offsets point at the correct chunk bytes after editing" do
    %{boxes: boxes, chunks: chunks} = build([<<10, 11>>, <<20, 21, 22>>, <<30>>])
    moved = List.insert_at(boxes, 1, %Box{type: "free", data: <<0, 0>>})
    fixed = ISOMedia.fix_chunk_offsets(moved)
    out = ISOMedia.serialize(fixed)

    chunks
    |> Enum.zip(stco_offsets(fixed))
    |> Enum.each(fn {chunk, off} ->
      assert binary_part(out, off, byte_size(chunk)) == chunk
    end)
  end

  test "raises when an mdat was synthesized (no source_offset)" do
    %{boxes: boxes} = build([<<1>>])
    # Replace mdat with a fresh (synthesized) one
    synth = %Box{type: "mdat", data: <<1>>}
    bad = Enum.map(boxes, fn b -> if b.type == "mdat", do: synth, else: b end)
    assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(bad) end
  end

  test "raises when a chunk offset falls outside any mdat" do
    %{boxes: boxes} = build([<<1, 2>>])
    bad =
      ISOMedia.Box.update(boxes, ~w(moov stco), fn stco ->
        co = ISOMedia.Boxes.ChunkOffset.decode(stco)
        ISOMedia.Boxes.ChunkOffset.encode(%{co | offsets: [999_999]})
      end)

    assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(bad) end
  end

  describe "co64 promotion" do
    test "promotes stco to co64 when an offset exceeds the threshold, chunks still resolve" do
      %{boxes: boxes, chunks: chunks} = build([<<10, 11>>, <<20, 21, 22>>])
      fixed = ISOMedia.Offsets.fix_chunk_offsets(boxes, co64_threshold: 5)

      co_box = ISOMedia.Box.find(fixed, ~w(moov co64))
      assert co_box != nil, "table should have been promoted to co64"
      co = ISOMedia.Boxes.ChunkOffset.decode(co_box)
      assert co.kind == :co64

      out = ISOMedia.serialize(fixed)

      chunks
      |> Enum.zip(co.offsets)
      |> Enum.each(fn {chunk, off} -> assert binary_part(out, off, byte_size(chunk)) == chunk end)
    end

    test "promotion converges and is idempotent (latched, never demoted)" do
      %{boxes: boxes} = build([<<1, 2>>, <<3, 4>>])
      once = ISOMedia.Offsets.fix_chunk_offsets(boxes, co64_threshold: 5)
      twice = ISOMedia.Offsets.fix_chunk_offsets(once, co64_threshold: 5)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
      assert ISOMedia.Box.find(twice, ~w(moov co64)) != nil
    end
  end
end
