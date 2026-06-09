defmodule ISOMedia.MdatSource do
  @moduledoc """
  Resolves an absolute file byte range to a payload segment, given the top-level
  `mdat` boxes of a parsed tree. Returns a `%FileSlice{}` when the containing `mdat`
  is lazy, or a `binary` slice when it is in memory. Shared by `Extract` and `Trim`.
  """

  alias ISOMedia.{Box, Layout, Payload}

  @doc """
  Capture each top-level `mdat`'s absolute payload range from a single `Layout` walk:
  `[%{box: mdat, payload_start: abs, payload_size: len}]`. The walk uses the same
  `Layout.box_size/1` the serializer uses, so the offsets are byte-identical to the
  written file — the basis for drift-free recursive resolution.
  """
  def collect(boxes) do
    boxes
    |> Layout.top_level_layout()
    |> Enum.filter(&(&1.box.type == "mdat"))
    |> Enum.map(fn %{box: box, payload_offset: payload_start} ->
      %{box: box, payload_start: payload_start, payload_size: Payload.size(box.data)}
    end)
  end

  @doc """
  Build a synthesized segment-list `mdat`, stamped with the basis position its chunk
  offsets were written against. `payload_start` is the absolute byte offset of the mdat
  payload in the layout its offsets were baked for (what the builder already computed to
  place chunks). The stamp gives `ISOMedia.Offsets.fix_chunk_offsets/1` a basis, so the
  table can be remapped if the mdat later moves — no disk round-trip needed.
  """
  def synthesized_mdat(segments, size_mode, payload_start) do
    box = %Box{type: "mdat", data: segments, size_mode: size_mode}

    %{
      box
      | source_offset: payload_start - Layout.header_size(box),
        source_size: Layout.box_size(box)
    }
  end

  @doc """
  Resolve the absolute `offset`..`offset+length` range to a payload segment, given the
  records from `collect/1`. Returns a `binary`, a `%FileSlice{}`, or (for a segment-list
  mdat) a nested segment list. Uses `relative = offset - payload_start`, so a physical
  `FileSlice` acts as a local byte provider (`fs.offset + relative`) independent of the
  absolute target.
  """
  def segment(records, offset, length) do
    rec =
      Enum.find(records, fn r ->
        offset >= r.payload_start and offset < r.payload_start + r.payload_size
      end) || raise ArgumentError, "byte range at offset #{offset} falls outside every mdat"

    Payload.slice(rec.box.data, offset - rec.payload_start, length)
  end
end
