defmodule ISOMedia.Extract do
  @moduledoc """
  Track discovery and single-track extraction.

  `track_ids/1` and `find_trak/2` locate tracks by their `tkhd` track_id;
  `extract_track/2` (added later) produces a new single-track tree.
  """

  alias ISOMedia.{Box, FileSlice, Layout, SampleTable}
  alias ISOMedia.Boxes.{ChunkOffset, TrackHeader}

  @uint32_max 0xFFFFFFFF

  @doc "List every track's `track_id`, in document order."
  def track_ids(boxes) do
    boxes
    |> traks()
    |> Enum.map(&track_id_of/1)
  end

  @doc "Find the `trak` box whose `tkhd` track_id matches, or `nil`."
  def find_trak(boxes, track_id) do
    boxes
    |> traks()
    |> Enum.find(fn trak -> track_id_of(trak) == track_id end)
  end

  defp traks(boxes) do
    case Enum.find(boxes, &(&1.type == "moov")) do
      nil -> []
      moov -> Enum.filter(moov.children, &(&1.type == "trak"))
    end
  end

  defp track_id_of(%Box{} = trak) do
    tkhd = Box.find([trak], ~w(trak tkhd)) || raise ArgumentError, "trak is missing tkhd"
    TrackHeader.decode(tkhd).track_id
  end

  @doc """
  Return a new box tree containing only the track `track_id`, with `mdat` rebuilt as a
  segment list of that track's chunks and `stco`/`co64` recomputed. Memory-safe: with a
  lazy source the segments are `FileSlice`s streamed on `write/2`.
  """
  def extract_track(boxes, track_id) do
    trak = find_trak(boxes, track_id) || raise ArgumentError, "no track with track_id #{track_id}"
    ftyp = Enum.find(boxes, &(&1.type == "ftyp")) || raise ArgumentError, "file has no ftyp"
    mdats = Enum.filter(boxes, &(&1.type == "mdat"))

    runs =
      trak
      |> SampleTable.build()
      |> Enum.chunk_by(& &1.chunk_index)
      |> Enum.map(fn chunk_samples ->
        {hd(chunk_samples).offset, Enum.sum(Enum.map(chunk_samples, & &1.size))}
      end)

    segments = Enum.map(runs, fn {off, len} -> segment_for(mdats, off, len) end)
    run_lengths = Enum.map(runs, fn {_o, l} -> l end)
    total = Enum.sum(run_lengths)
    chunk_count = length(runs)

    zeros = List.duplicate(0, chunk_count)

    # Decide co64 vs stco and the mdat header size up front (both knowable now).
    # Upper bound uses the larger co64 table + 16-byte mdat header; output ≤ original.
    co64_bound =
      Layout.box_size(ftyp) + Layout.box_size(rebuild_moov(boxes, trak, offset_box(:co64, zeros))) +
        16 + total

    co_kind = if co64_bound > @uint32_max, do: :co64, else: :stco
    mdat_mode = if 8 + total > @uint32_max, do: :large, else: :compact
    mdat_header = if mdat_mode == :large, do: 16, else: 8

    # Size moov with dummy offsets of the chosen kind, then place real offsets.
    moov0 = rebuild_moov(boxes, trak, offset_box(co_kind, zeros))
    mdat_payload_start = Layout.box_size(ftyp) + Layout.box_size(moov0) + mdat_header

    {chunk_offsets, _} =
      Enum.map_reduce(run_lengths, mdat_payload_start, fn len, pos -> {pos, pos + len} end)

    moov = rebuild_moov(boxes, trak, offset_box(co_kind, chunk_offsets))
    mdat = %Box{type: "mdat", data: segments, size_mode: mdat_mode}
    [ftyp, moov, mdat]
  end

  # --- helpers ---

  defp offset_box(kind, offsets) do
    ChunkOffset.encode(%ChunkOffset{kind: kind, version: 0, flags: <<0, 0, 0>>, offsets: offsets})
  end

  defp segment_for(mdats, offset, length) do
    mdat =
      Enum.find(mdats, fn m ->
        not is_nil(m.source_offset) and offset >= m.source_offset and
          offset < m.source_offset + m.source_size
      end) || raise ArgumentError, "sample chunk at offset #{offset} falls outside every mdat"

    case mdat.data do
      %FileSlice{path: path} ->
        %FileSlice{path: path, offset: offset, length: length}

      bin when is_binary(bin) ->
        payload_start = mdat.source_offset + Layout.header_size(mdat)
        binary_part(bin, offset - payload_start, length)

      _ ->
        raise ArgumentError, "cannot extract from an mdat whose payload is already a segment list"
    end
  end

  defp rebuild_moov(boxes, trak, new_offset_box) do
    moov = Enum.find(boxes, &(&1.type == "moov"))
    kept = replace_offset_box(trak, new_offset_box)
    keep_id = track_id_of(trak)

    children =
      Enum.flat_map(moov.children, fn
        %Box{type: "trak"} = t -> if track_id_of(t) == keep_id, do: [kept], else: []
        other -> [other]
      end)

    %{moov | children: children}
  end

  defp replace_offset_box(trak, new_box) do
    update_descendant(trak, ~w(mdia minf stbl), fn stbl ->
      children =
        Enum.map(stbl.children, fn
          %Box{type: t} when t in ["stco", "co64"] -> new_box
          other -> other
        end)

      %{stbl | children: children}
    end)
  end

  defp update_descendant(box, [], fun), do: fun.(box)

  defp update_descendant(%Box{children: children} = box, [type | rest], fun) do
    new_children =
      Enum.map(children, fn
        %Box{type: ^type} = c -> update_descendant(c, rest, fun)
        other -> other
      end)

    %{box | children: new_children}
  end
end
