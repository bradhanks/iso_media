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

  defp co64_data(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::64>>
    <<0, 0, 0, 0, length(offsets)::32, entries::binary>>
  end

  defp table(:stco, offsets), do: leaf("stco", stco_data(offsets))
  defp table(:co64, offsets), do: leaf("co64", co64_data(offsets))

  # A full trak with the real stbl path down to its chunk-offset table.
  defp trak(table_box) do
    container("trak", container("mdia", container("minf", container("stbl", table_box))))
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

  # A synthesized progressive tree [ftyp, moov, mdat] from the real fixture, via
  # extract_track (its mdat is a segment list with no parsed source position).
  defp synth_track do
    original = File.read!(Path.join([__DIR__, "..", "fixtures", "sample.mp4"]))
    {:ok, boxes} = ISOMedia.parse(original)
    [tid | _] = ISOMedia.track_ids(boxes)
    synth = ISOMedia.extract_track(boxes, tid)
    [synth_tid | _] = ISOMedia.track_ids(synth)
    {synth, synth_tid}
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

  describe "faststart" do
    test "no-op when there is no moov or no mdat" do
      boxes = [%Box{type: "ftyp", data: <<0, 0, 0, 0>>}]
      assert ISOMedia.faststart(boxes) == boxes
    end

    test "moves moov before mdat and keeps every chunk resolvable on the real fixture" do
      original = File.read!(Path.join([__DIR__, "..", "fixtures", "sample.mp4"]))
      {:ok, boxes} = ISOMedia.parse(original)

      old_offsets =
        boxes
        |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
        |> Enum.flat_map(fn b ->
          ISOMedia.Boxes.ChunkOffset.decode(b).offsets
        end)

      assert old_offsets != [], "fixture should have at least one stco entry"

      fixed = ISOMedia.faststart(boxes)
      out = ISOMedia.serialize(fixed)

      # moov now precedes mdat
      types = Enum.map(fixed, & &1.type)
      assert Enum.find_index(types, &(&1 == "moov")) < Enum.find_index(types, &(&1 == "mdat"))

      new_offsets =
        fixed
        |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
        |> Enum.flat_map(fn b ->
          ISOMedia.Boxes.ChunkOffset.decode(b).offsets
        end)

      # Same number of entries before and after, so the zip below can't silently
      # drop a mismatched chunk.
      assert length(old_offsets) == length(new_offsets)

      # Each chunk's bytes at the new offset match the bytes at the old offset in the
      # original file (first 16 bytes is enough to prove the offset points at the
      # same chunk data).
      Enum.zip(old_offsets, new_offsets)
      |> Enum.each(fn {old, new} ->
        k = min(16, byte_size(original) - old)
        assert binary_part(out, new, k) == binary_part(original, old, k)
      end)
    end
  end

  describe "multiple tables and mdats" do
    test "faststart on a co64-based file keeps it co64 and resolvable" do
      ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
      chunks = [<<1, 2>>, <<3, 4, 5>>]
      payload = IO.iodata_to_binary(chunks)

      # moov size is independent of offset values, so size with zeros then fill in.
      moov0 = container("moov", trak(table(:co64, [0, 0])))
      start = byte_size(ftyp) + byte_size(moov0) + 8
      {offs, _} = Enum.map_reduce(chunks, start, fn c, p -> {p, p + byte_size(c)} end)
      moov = container("moov", trak(table(:co64, offs)))
      {:ok, boxes} = ISOMedia.parse(ftyp <> moov <> leaf("mdat", payload))

      fixed = ISOMedia.faststart(boxes)
      out = ISOMedia.serialize(fixed)

      co_box = ISOMedia.Box.find(fixed, ~w(moov trak mdia minf stbl co64))
      assert co_box != nil, "table should still be co64"
      co = ISOMedia.Boxes.ChunkOffset.decode(co_box)
      assert co.kind == :co64

      chunks
      |> Enum.zip(co.offsets)
      |> Enum.each(fn {chunk, off} -> assert binary_part(out, off, byte_size(chunk)) == chunk end)
    end

    test "faststart remaps every trak's stco when a moov has multiple tracks" do
      ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
      a = <<1, 2, 3>>
      b = <<4, 5>>
      payload = a <> b

      moov0 = container("moov", trak(table(:stco, [0])) <> trak(table(:stco, [0])))
      start = byte_size(ftyp) + byte_size(moov0) + 8
      off_a = start
      off_b = start + byte_size(a)
      moov = container("moov", trak(table(:stco, [off_a])) <> trak(table(:stco, [off_b])))
      {:ok, boxes} = ISOMedia.parse(ftyp <> moov <> leaf("mdat", payload))

      fixed = ISOMedia.faststart(boxes)
      out = ISOMedia.serialize(fixed)

      offsets =
        fixed
        |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
        |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)

      assert [new_a, new_b] = offsets
      assert binary_part(out, new_a, byte_size(a)) == a
      assert binary_part(out, new_b, byte_size(b)) == b
    end

    test "a chunk in each of two mdats gets remapped by that mdat's own delta" do
      ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
      a = <<1, 2, 3>>
      b = <<4, 5>>

      moov0 = container("moov", trak(table(:stco, [0, 0])))
      mdat1_start = byte_size(ftyp) + byte_size(moov0)
      off_a = mdat1_start + 8
      mdat2_start = mdat1_start + 8 + byte_size(a)
      off_b = mdat2_start + 8
      moov = container("moov", trak(table(:stco, [off_a, off_b])))
      bin = ftyp <> moov <> leaf("mdat", a) <> leaf("mdat", b)
      {:ok, boxes} = ISOMedia.parse(bin)

      # Insert a free box (total 12 bytes) BETWEEN the two mdats. mdat1 is unmoved
      # (delta 0); mdat2 shifts down by 12 — so the two chunks get different deltas.
      free = %Box{type: "free", data: <<0, 0, 0, 0>>}
      # top-level order is [ftyp, moov, mdat1, mdat2]; insert before mdat2 (index 3)
      moved = List.insert_at(boxes, 3, free)
      fixed = ISOMedia.fix_chunk_offsets(moved)
      out = ISOMedia.serialize(fixed)

      assert [new_a, new_b] =
               ISOMedia.Box.find(fixed, ~w(moov trak mdia minf stbl stco))
               |> ISOMedia.Boxes.ChunkOffset.decode()
               |> Map.fetch!(:offsets)

      assert new_a == off_a
      assert new_b == off_b + 12
      assert binary_part(out, new_a, byte_size(a)) == a
      assert binary_part(out, new_b, byte_size(b)) == b
    end
  end

  describe "synthesized mdat (in-memory fix/faststart)" do
    test "fix_chunk_offsets is a no-op on a freshly synthesized tree" do
      {synth, _tid} = synth_track()
      fixed = ISOMedia.fix_chunk_offsets(synth)
      assert ISOMedia.serialize(fixed) == ISOMedia.serialize(synth)
    end

    test "faststart is a no-op on a synthesized [ftyp, moov, mdat] tree" do
      {synth, _tid} = synth_track()
      assert ISOMedia.serialize(ISOMedia.faststart(synth)) == ISOMedia.serialize(synth)
    end

    test "fix_chunk_offsets remaps every sample to its correct bytes after the mdat moves" do
      {synth, tid} = synth_track()
      before_bin = ISOMedia.serialize(synth)

      expected =
        Enum.map(ISOMedia.samples(synth, tid), fn s ->
          :binary.part(before_bin, s.offset, s.size)
        end)

      # free box total size = 8 header + 4 data = 12; inserting before mdat shifts it down.
      moved = List.insert_at(synth, 2, %Box{type: "free", data: <<0, 0, 0, 0>>})
      fixed = ISOMedia.fix_chunk_offsets(moved)
      after_bin = ISOMedia.serialize(fixed)
      new_samples = ISOMedia.samples(fixed, tid)

      assert length(new_samples) == length(expected)

      Enum.zip(expected, new_samples)
      |> Enum.each(fn {bytes, s} ->
        assert :binary.part(after_bin, s.offset, s.size) == bytes
      end)
    end

    test "promotes stco to co64 on a synthesized tree and samples still resolve" do
      {synth, tid} = synth_track()
      base = ISOMedia.serialize(synth)
      expected = Enum.map(ISOMedia.samples(synth, tid), fn s -> :binary.part(base, s.offset, s.size) end)

      # Threshold 1 forces promotion: every real chunk offset exceeds it.
      fixed = ISOMedia.Offsets.fix_chunk_offsets(synth, co64_threshold: 1)
      assert ISOMedia.Box.find(fixed, ~w(moov trak mdia minf stbl co64)) != nil

      out = ISOMedia.serialize(fixed)
      # Zip by sample index (robust even when several samples share a size); the bytes
      # are unchanged content, only their absolute offsets move with the larger co64 table.
      Enum.zip(expected, ISOMedia.samples(fixed, tid))
      |> Enum.each(fn {bytes, s} -> assert :binary.part(out, s.offset, s.size) == bytes end)
    end

    test "fix_chunk_offsets is idempotent after a move" do
      {synth, _tid} = synth_track()
      moved = List.insert_at(synth, 2, %Box{type: "free", data: <<0, 0, 0, 0>>})
      once = ISOMedia.fix_chunk_offsets(moved)
      twice = ISOMedia.fix_chunk_offsets(once)
      assert ISOMedia.serialize(twice) == ISOMedia.serialize(once)
    end

    test "still raises when a stamped mdat's size no longer matches its basis" do
      {synth, _tid} = synth_track()
      # Prepend a byte to the mdat segment list: box_size now != stamped source_size.
      grown =
        Enum.map(synth, fn b ->
          if b.type == "mdat", do: %{b | data: [<<0>> | b.data]}, else: b
        end)

      assert_raise ArgumentError, fn -> ISOMedia.fix_chunk_offsets(grown) end
    end
  end
end
