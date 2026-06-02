defmodule ISOMedia.Support.MP4Builder do
  @moduledoc """
  Test helper: builds a minimal, structurally-real ISOBMFF binary with an `mdat`
  containing the given chunks (concatenated) and a `moov/trak/mdia/minf/stbl/stco`
  whose offsets point at each chunk's absolute file position. Returns the binary
  plus the expected offsets so tests can verify chunk resolution.
  """

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  defp stco(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::32>>
    leaf("stco", <<0, 0, 0, 0, length(offsets)::32, entries::binary>>)
  end

  # moov containing the real stbl path down to stco.
  defp moov(offsets) do
    stbl = container("stbl", stco(offsets))
    minf = container("minf", stbl)
    mdia = container("mdia", minf)
    trak = container("trak", mdia)
    container("moov", trak)
  end

  @doc """
  Build `%{binary: binary, offsets: [int], chunks: [binary], mdat_payload_start: int}`.

  Options:
    * `:moov_position` — `:first` (default, layout `ftyp, moov, mdat`) or `:last`
      (layout `ftyp, mdat, moov`). Use `:last` to make `faststart/1` a real
      relocation rather than a no-op.
  """
  def build(chunks, opts \\ []) when is_list(chunks) and chunks != [] do
    position = Keyword.get(opts, :moov_position, :first)
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # When moov comes first, the chunks sit after ftyp + moov; moov's byte length is
    # independent of the offset *values* (fixed-width entries), so size it with zeros.
    # When moov comes last, the chunks sit immediately after ftyp.
    mdat_payload_start =
      case position do
        :first -> byte_size(ftyp) + byte_size(moov(List.duplicate(0, length(chunks)))) + 8
        :last -> byte_size(ftyp) + 8
      end

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    mdat = leaf("mdat", mdat_payload)

    binary =
      case position do
        :first -> ftyp <> moov(offsets) <> mdat
        :last -> ftyp <> mdat <> moov(offsets)
      end

    %{binary: binary, offsets: offsets, chunks: chunks, mdat_payload_start: mdat_payload_start}
  end

  @doc """
  Build a multi-track file from specs `%{id: track_id, chunks: [[sample_binary]]}`.
  Chunks are interleaved round-robin across tracks in the mdat (so a track's chunks
  are scattered, exercising real extraction). Returns
  `%{binary: binary, specs: specs}`.
  """
  def build_tracks(specs) when is_list(specs) and specs != [] do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)

    # mdat layout: round-robin chunk i of each track, in spec order.
    interleave = interleave_chunks(specs)
    chunk_lengths = Enum.map(interleave, fn {_id, bytes} -> byte_size(bytes) end)

    # Two-pass: size moov with zero offsets, then place real ones. Table sizes are
    # independent of offset *values*, so moov's byte size is stable.
    zero = Map.new(specs, fn s -> {s.id, List.duplicate(0, length(s.chunks))} end)
    mdat_payload_start = byte_size(ftyp) + byte_size(moov(specs, zero)) + 8

    {abs_offsets, _} =
      Enum.map_reduce(chunk_lengths, mdat_payload_start, fn len, pos -> {pos, pos + len} end)

    per_track = group_offsets(interleave, abs_offsets)
    mdat_payload = IO.iodata_to_binary(Enum.map(interleave, fn {_id, b} -> b end))
    binary = ftyp <> moov(specs, per_track) <> leaf("mdat", mdat_payload)

    %{binary: binary, specs: specs}
  end

  defp interleave_chunks(specs) do
    per_track = Enum.map(specs, fn s -> {s.id, Enum.map(s.chunks, &IO.iodata_to_binary/1)} end)
    max_len = per_track |> Enum.map(fn {_id, cs} -> length(cs) end) |> Enum.max()

    for i <- 0..(max_len - 1)//1,
        {id, cs} <- per_track,
        i < length(cs),
        do: {id, Enum.at(cs, i)}
  end

  defp group_offsets(interleave, offsets) do
    interleave
    |> Enum.zip(offsets)
    |> Enum.reduce(%{}, fn {{id, _b}, off}, acc -> Map.update(acc, id, [off], &(&1 ++ [off])) end)
  end

  defp moov(specs, offsets_map) do
    traks = Enum.map(specs, fn s -> trak(s, Map.fetch!(offsets_map, s.id)) end)
    container("moov", IO.iodata_to_binary(traks))
  end

  defp trak(spec, chunk_offsets) do
    sample_sizes = spec.chunks |> List.flatten() |> Enum.map(&byte_size/1)
    spc = Enum.map(spec.chunks, &length/1)
    n = length(sample_sizes)
    durations = Map.get(spec, :durations, List.duplicate(1, n))
    sync = Map.get(spec, :sync, nil)

    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = stts_box(durations)
    stsc = stsc_box(spc)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, n::32, sizes_bin(sample_sizes)::binary>>)

    stco =
      leaf("stco", <<0, 0, 0, 0, length(chunk_offsets)::32, offsets_bin(chunk_offsets)::binary>>)

    stss = if sync, do: stss_box(sync), else: <<>>
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco <> stss)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, spec.id::32, 0::32, 0::32>>)
    mdhd = leaf("mdhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::16, 0::16>>)
    mdia = container("mdia", mdhd <> container("minf", stbl))
    container("trak", tkhd <> mdia)
  end

  defp stts_box(durations) do
    entries =
      durations
      |> Enum.chunk_by(& &1)
      |> Enum.map(fn run -> <<length(run)::32, hd(run)::32>> end)
      |> IO.iodata_to_binary()

    count = durations |> Enum.chunk_by(& &1) |> length()
    leaf("stts", <<0, 0, 0, 0, count::32, entries::binary>>)
  end

  defp stss_box(sync) do
    entries = for n <- sync, into: <<>>, do: <<n::32>>
    leaf("stss", <<0, 0, 0, 0, length(sync)::32, entries::binary>>)
  end

  defp stsc_box(spc) do
    entries =
      spc
      |> Enum.with_index(1)
      |> Enum.map(fn {n, i} -> <<i::32, n::32, 1::32>> end)
      |> IO.iodata_to_binary()

    leaf("stsc", <<0, 0, 0, 0, length(spc)::32, entries::binary>>)
  end

  defp sizes_bin(sizes), do: for(s <- sizes, into: <<>>, do: <<s::32>>)
  defp offsets_bin(offsets), do: for(o <- offsets, into: <<>>, do: <<o::32>>)
end
