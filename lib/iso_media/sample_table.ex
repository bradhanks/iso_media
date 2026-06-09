defmodule ISOMedia.SampleTable do
  @moduledoc """
  Decodes a track's `stbl` sample tables into an ordered list of `ISOMedia.Sample`.

  Cross-references `stsz` (sizes), `stsc` (sample→chunk runs), `stco`/`co64` (chunk
  offsets), `stts` (decode-time deltas), optional `ctts` (composition offsets) and
  `stss` (sync samples). Raises on `stz2` (unsupported) or a missing required table.
  """

  alias ISOMedia.{Box, BoxPath, FullBox, Sample}
  alias ISOMedia.Boxes.ChunkOffset

  # Sanity ceiling on a track's sample count. The chunk structure (`stco`/`stsc`) is
  # the only table that backs a sample count with bytes-on-disk, so it is computed
  # first and used to bound every other table's run-length expansion — a hostile box
  # cannot claim billions of samples and force a multi-GB allocation. 100M samples is
  # ~46 days of 25fps video; no real file approaches it.
  @max_samples 100_000_000

  @doc "Decode a `trak` box into `[%ISOMedia.Sample{}]`."
  def build(%Box{type: "trak"} = trak) do
    stbl = dig(trak, ~w(mdia minf stbl)) || raise ArgumentError, "trak is missing mdia/minf/stbl"

    chunk_offsets = chunk_offsets(stbl)
    spc = expand_stsc(stsc_entries(stbl), length(chunk_offsets))
    sample_count = Enum.sum(spc)

    if sample_count > @max_samples do
      raise ArgumentError,
            "stbl declares #{sample_count} samples, exceeds the #{@max_samples} ceiling"
    end

    sizes = sample_sizes(stbl, sample_count)
    durations = decode_durations(stbl, sample_count)
    dts = cumulative(durations)
    ctts = decode_ctts(stbl, sample_count)
    sync = sync_set(stbl)

    assemble(sizes, chunk_offsets, spc, durations, dts, ctts, sync)
  end

  @doc "Encode a `stts` box from a per-sample duration list (run-length encoded)."
  def build_stts(durations) do
    entries = rle(durations)
    body = for {n, d} <- entries, into: <<>>, do: <<n::32, d::32>>
    leaf("stts", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
  end

  @doc "Encode a `stsz` box from explicit per-sample sizes."
  def build_stsz(sizes) do
    body = for s <- sizes, into: <<>>, do: <<s::32>>
    leaf("stsz", <<0, 0, 0, 0, 0::32, length(sizes)::32, body::binary>>)
  end

  @doc "Encode a `ctts` box from per-sample composition offsets, or `nil` if all zero."
  def build_ctts(offsets) do
    cond do
      Enum.all?(offsets, &(&1 == 0)) ->
        nil

      Enum.any?(offsets, &(&1 < 0)) ->
        entries = rle(offsets)
        body = for {n, off} <- entries, into: <<>>, do: <<n::32, off::signed-32>>
        leaf("ctts", <<1::8, 0::24, length(entries)::32, body::binary>>)

      true ->
        entries = rle(offsets)
        body = for {n, off} <- entries, into: <<>>, do: <<n::32, off::32>>
        leaf("ctts", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
    end
  end

  @doc "Encode a `stss` box from 1-based sync sample positions."
  def build_stss(positions) do
    body = for n <- positions, into: <<>>, do: <<n::32>>
    leaf("stss", <<0, 0, 0, 0, length(positions)::32, body::binary>>)
  end

  @doc "Encode a `stsc` box from per-chunk sample counts (chunk order, 1-based chunks)."
  def build_stsc(per_chunk_counts) do
    entries =
      per_chunk_counts
      |> Enum.with_index(1)
      |> Enum.chunk_by(fn {count, _chunk} -> count end)
      |> Enum.map(fn [{count, first_chunk} | _] = _run -> {first_chunk, count} end)

    body =
      for {first_chunk, count} <- entries, into: <<>>, do: <<first_chunk::32, count::32, 1::32>>

    leaf("stsc", <<0, 0, 0, 0, length(entries)::32, body::binary>>)
  end

  defp rle(values) do
    values |> Enum.chunk_by(& &1) |> Enum.map(fn run -> {length(run), hd(run)} end)
  end

  defp leaf(type, data), do: %ISOMedia.Box{type: type, data: data}

  # --- table decoders ---

  defp sample_sizes(stbl, expected) do
    cond do
      box = dig(stbl, ["stsz"]) ->
        {_v, _f, <<sample_size::32, count::32, rest::binary>>} = FullBox.parse(box.data)

        if sample_size == 0 do
          sizes = for <<s::32 <- rest>>, do: s

          if length(sizes) != count,
            do: raise(ArgumentError, "stsz: declared #{count} sizes but found #{length(sizes)}")

          if length(sizes) != expected do
            raise ArgumentError,
                  "stsc/stsz mismatch: chunks describe #{expected} samples but stsz has #{length(sizes)}"
          end

          sizes
        else
          # Constant size: `count` has no per-sample byte backing, so it is validated
          # against the chunk-implied count before expansion to bound the allocation.
          if count != expected do
            raise ArgumentError,
                  "stsc/stsz mismatch: chunks describe #{expected} samples but stsz has #{count}"
          end

          List.duplicate(sample_size, count)
        end

      dig(stbl, ["stz2"]) ->
        raise ArgumentError,
              "Unsupported sample-size table: stz2 (compact sizes). Please open an issue if you hit this."

      true ->
        raise ArgumentError, "stbl is missing stsz (sample size box)"
    end
  end

  defp chunk_offsets(stbl) do
    box =
      dig(stbl, ["stco"]) || dig(stbl, ["co64"]) ||
        raise ArgumentError, "stbl is missing stco/co64"

    ChunkOffset.decode(box).offsets
  end

  defp stsc_entries(stbl) do
    box = dig(stbl, ["stsc"]) || raise ArgumentError, "stbl is missing stsc"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    for <<first_chunk::32, spc::32, _sdi::32 <- rest>>, do: {first_chunk, spc}
  end

  # Per-chunk samples-per-chunk for chunks 1..chunk_count. `stsc` entries are runs
  # `{first_chunk, samples_per_chunk}`; the spc for chunk c is that of the last run
  # whose first_chunk <= c. Walking chunks and runs in lockstep is O(chunks + runs).
  defp expand_stsc(_entries, 0), do: []

  defp expand_stsc(entries, chunk_count) do
    sorted = Enum.sort_by(entries, &elem(&1, 0))

    unless match?([{1, _} | _], sorted) do
      raise ArgumentError, "stsc: no run covers chunk 1"
    end

    {acc, _runs, _spc} =
      Enum.reduce(1..chunk_count//1, {[], sorted, 0}, fn c, {acc, runs, spc} ->
        {spc, runs} = advance_stsc(runs, c, spc)
        {[spc | acc], runs, spc}
      end)

    Enum.reverse(acc)
  end

  defp advance_stsc([{fc, spc} | rest], c, _cur) when fc <= c, do: advance_stsc(rest, c, spc)
  defp advance_stsc(runs, _c, cur), do: {cur, runs}

  defp decode_durations(stbl, sample_count) do
    box = dig(stbl, ["stts"]) || raise ArgumentError, "stbl is missing stts"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    deltas = for <<n::32, delta::32 <- rest>>, do: {n, delta}
    expand_runs(deltas, sample_count, "stts")
  end

  defp cumulative(durations) do
    {dts, _} = Enum.map_reduce(durations, 0, fn d, acc -> {acc, acc + d} end)
    dts
  end

  defp decode_ctts(stbl, sample_count) do
    case dig(stbl, ["ctts"]) do
      nil ->
        List.duplicate(0, sample_count)

      box ->
        {version, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)

        entries =
          case version do
            1 -> for <<n::32, off::signed-32 <- rest>>, do: {n, off}
            _ -> for <<n::32, off::32 <- rest>>, do: {n, off}
          end

        expand_runs(entries, sample_count, "ctts")
    end
  end

  # Run-length expand `[{count, value}]` to a flat list of exactly `expected` values.
  # Accumulates the running total and raises *before* duplicating once it would exceed
  # `expected`, so a hostile run-length (up to 2^32-1) can never drive the allocation
  # past the chunk-bounded sample count.
  defp expand_runs(entries, expected, label) do
    {rev, total} =
      Enum.reduce(entries, {[], 0}, fn {n, value}, {acc, total} ->
        total = total + n

        if total > expected do
          raise ArgumentError, "#{label} describes more than #{expected} samples"
        end

        {[List.duplicate(value, n) | acc], total}
      end)

    if total != expected do
      raise ArgumentError, "#{label} describes #{total} samples, expected #{expected}"
    end

    rev |> Enum.reverse() |> List.flatten()
  end

  defp sync_set(stbl) do
    case dig(stbl, ["stss"]) do
      nil ->
        :all

      box ->
        {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
        MapSet.new(for <<n::32 <- rest>>, do: n)
    end
  end

  # --- assembly ---

  defp assemble(sizes, chunk_offsets, spc, durations, dts, ctts, sync) do
    chunks = Enum.zip([1..length(chunk_offsets)//1, chunk_offsets, spc])

    {rev, _state} =
      Enum.reduce(chunks, {[], {1, sizes, durations, dts, ctts}}, fn {cidx, coff, n},
                                                                     {acc, {sidx, sz, du, dt, ct}} ->
        {csz, sz2} = Enum.split(sz, n)
        {cdu, du2} = Enum.split(du, n)
        {cdt, dt2} = Enum.split(dt, n)
        {cct, ct2} = Enum.split(ct, n)

        {chunk_acc, _pos, _i} =
          Enum.reduce(Enum.zip([csz, cdu, cdt, cct]), {acc, coff, sidx}, fn {size, dur, d, c},
                                                                            {a, pos, i} ->
            sample = %Sample{
              index: i,
              chunk_index: cidx,
              dts: d,
              duration: dur,
              pts: d + c,
              size: size,
              offset: pos,
              sync?: sync == :all or MapSet.member?(sync, i)
            }

            {[sample | a], pos + size, i + 1}
          end)

        {chunk_acc, {sidx + n, sz2, du2, dt2, ct2}}
      end)

    Enum.reverse(rev)
  end

  defp dig(box, path), do: BoxPath.dig(box, path)
end
