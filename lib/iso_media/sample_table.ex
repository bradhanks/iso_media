defmodule ISOMedia.SampleTable do
  @moduledoc """
  Decodes a track's `stbl` sample tables into an ordered list of `ISOMedia.Sample`.

  Cross-references `stsz` (sizes), `stsc` (sample→chunk runs), `stco`/`co64` (chunk
  offsets), `stts` (decode-time deltas), optional `ctts` (composition offsets) and
  `stss` (sync samples). Raises on `stz2` (unsupported) or a missing required table.
  """

  alias ISOMedia.{Box, FullBox, Sample}
  alias ISOMedia.Boxes.ChunkOffset

  @doc "Decode a `trak` box into `[%ISOMedia.Sample{}]`."
  def build(%Box{type: "trak"} = trak) do
    stbl = dig(trak, ~w(mdia minf stbl)) || raise ArgumentError, "trak is missing mdia/minf/stbl"

    sizes = sample_sizes(stbl)
    sample_count = length(sizes)
    chunk_offsets = chunk_offsets(stbl)
    spc = expand_stsc(stsc_entries(stbl), length(chunk_offsets))

    if Enum.sum(spc) != sample_count do
      raise ArgumentError,
            "stsc/stsz mismatch: chunks describe #{Enum.sum(spc)} samples but stsz has #{sample_count}"
    end

    dts = decode_dts(stbl, sample_count)
    ctts = decode_ctts(stbl, sample_count)
    sync = sync_set(stbl)

    assemble(sizes, chunk_offsets, spc, dts, ctts, sync)
  end

  # --- table decoders ---

  defp sample_sizes(stbl) do
    cond do
      box = dig(stbl, ["stsz"]) ->
        {_v, _f, <<sample_size::32, count::32, rest::binary>>} = FullBox.parse(box.data)

        if sample_size == 0 do
          sizes = for <<s::32 <- rest>>, do: s

          if length(sizes) != count,
            do: raise(ArgumentError, "stsz: declared #{count} sizes but found #{length(sizes)}")

          sizes
        else
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

  # Per-chunk samples-per-chunk for chunks 1..chunk_count (entries are runs).
  defp expand_stsc(entries, chunk_count) do
    sorted = Enum.sort_by(entries, &elem(&1, 0))

    Enum.map(1..chunk_count//1, fn c ->
      case sorted |> Enum.take_while(fn {fc, _} -> fc <= c end) |> List.last() do
        {_fc, spc} -> spc
        nil -> raise ArgumentError, "stsc: no run covers chunk #{c}"
      end
    end)
  end

  defp decode_dts(stbl, sample_count) do
    box = dig(stbl, ["stts"]) || raise ArgumentError, "stbl is missing stts"
    {_v, _f, <<_count::32, rest::binary>>} = FullBox.parse(box.data)
    deltas = for <<n::32, delta::32 <- rest>>, do: {n, delta}
    per_sample = Enum.flat_map(deltas, fn {n, d} -> List.duplicate(d, n) end)

    if length(per_sample) != sample_count,
      do:
        raise(
          ArgumentError,
          "stts describes #{length(per_sample)} samples, expected #{sample_count}"
        )

    {dts, _} = Enum.map_reduce(per_sample, 0, fn d, acc -> {acc, acc + d} end)
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

        Enum.flat_map(entries, fn {n, off} -> List.duplicate(off, n) end)
    end
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

  defp assemble(sizes, chunk_offsets, spc, dts, ctts, sync) do
    chunks = Enum.zip([1..length(chunk_offsets)//1, chunk_offsets, spc])

    {rev, _state} =
      Enum.reduce(chunks, {[], {1, sizes, dts, ctts}}, fn {cidx, coff, n},
                                                          {acc, {sidx, sz, dt, ct}} ->
        {csz, sz2} = Enum.split(sz, n)
        {cdt, dt2} = Enum.split(dt, n)
        {cct, ct2} = Enum.split(ct, n)

        {chunk_acc, _pos, _i} =
          Enum.reduce(Enum.zip([csz, cdt, cct]), {acc, coff, sidx}, fn {size, d, c},
                                                                       {a, pos, i} ->
            sample = %Sample{
              index: i,
              chunk_index: cidx,
              dts: d,
              pts: d + c,
              size: size,
              offset: pos,
              sync?: sync == :all or MapSet.member?(sync, i)
            }

            {[sample | a], pos + size, i + 1}
          end)

        {chunk_acc, {sidx + n, sz2, dt2, ct2}}
      end)

    Enum.reverse(rev)
  end

  # Navigate a single box by child-type path (e.g. dig(trak, ~w(mdia minf stbl))).
  defp dig(%Box{type: type} = box, path), do: Box.find([box], [type | path])
end
