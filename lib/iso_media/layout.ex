defmodule ISOMedia.Layout do
  @moduledoc """
  Computes absolute byte offsets for a box tree in its current arrangement,
  matching exactly how `ISOMedia.Serializer` lays bytes out. Used to find where
  boxes land after editing so chunk offsets can be recomputed.
  """

  alias ISOMedia.Box
  alias ISOMedia.FileSlice

  @doc "Byte length of a box's header (size+type, +8 for largesize, +16 for uuid)."
  def header_size(%Box{size_mode: mode, uuid: uuid}) do
    base =
      case mode do
        :compact -> 8
        :large -> 16
        :eof -> 8
      end

    base + if(uuid, do: 16, else: 0)
  end

  @doc "Total serialized byte length of a box (header + uuid + payload/children)."
  def box_size(%Box{data: %FileSlice{length: len}} = box), do: header_size(box) + len

  def box_size(%Box{data: nil, children: children} = box) do
    header_size(box) + Enum.sum(Enum.map(children, &box_size/1))
  end

  def box_size(%Box{data: data} = box) do
    header_size(box) + byte_size(data)
  end

  @doc """
  Absolute layout of the top-level boxes: a list of
  `%{box: box, offset: abs_offset, payload_offset: abs_payload_offset}` in order.
  """
  def top_level_layout(boxes) when is_list(boxes) do
    {entries, _end} =
      Enum.map_reduce(boxes, 0, fn box, off ->
        entry = %{box: box, offset: off, payload_offset: off + header_size(box)}
        {entry, off + box_size(box)}
      end)

    entries
  end
end
