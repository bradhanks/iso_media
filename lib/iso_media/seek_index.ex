defmodule ISOMedia.SeekIndex do
  @moduledoc """
  A random-access index over a box tree's would-be `serialize/1` output.

  `build/1` flattens the tree (mirroring `ISOMedia.Serializer`) into an offset-ordered
  tuple of physical segments `%{abs_offset, size, provider}`, where
  `provider :: {:bytes, binary} | {:slice, ISOMedia.FileSlice.t()}`. `read_range/3` and
  `stream_range/4` resolve any byte range against the index, reading only the disk bytes
  the range touches. Build once, query many times. The index is opaque.
  """

  alias ISOMedia.{Box, FileSlice, Serializer}

  defstruct [:segments, :count, :byte_size]

  @type t :: %__MODULE__{segments: tuple(), count: non_neg_integer(), byte_size: non_neg_integer()}

  @doc "Build the index from a `%Box{}` or list of boxes (same shapes `serialize/1` accepts)."
  def build(%Box{} = box), do: build([box])

  def build(boxes) when is_list(boxes) do
    {rev, total} = walk(boxes, 0, [])
    segments = rev |> Enum.reverse() |> List.to_tuple()
    %__MODULE__{segments: segments, count: tuple_size(segments), byte_size: total}
  end

  @doc "Total size of the serialized output (the HTTP `Content-Length`); reads no payload bytes."
  def content_length(%__MODULE__{byte_size: bs}), do: bs

  # --- build walk: record physical runs in the exact order serialize/1 emits them ---

  defp walk(boxes, off, acc) do
    Enum.reduce(boxes, {acc, off}, fn box, {a, o} -> walk_box(box, o, a) end)
  end

  defp walk_box(%Box{} = box, off, acc) do
    header = Serializer.header_bytes(box)
    hsize = byte_size(header)
    walk_payload(box, off + hsize, emit(acc, off, hsize, {:bytes, header}))
  end

  # container: header only, then recurse into children
  defp walk_payload(%Box{data: nil, children: children}, off, acc), do: walk(children, off, acc)

  defp walk_payload(%Box{data: %FileSlice{length: len} = fs}, off, acc),
    do: {emit(acc, off, len, {:slice, fs}), off + len}

  defp walk_payload(%Box{data: parts}, off, acc) when is_list(parts),
    do: walk_segments(parts, off, acc)

  defp walk_payload(%Box{data: data}, off, acc) when is_binary(data),
    do: {emit(acc, off, byte_size(data), {:bytes, data}), off + byte_size(data)}

  defp walk_segments(parts, off, acc) do
    Enum.reduce(parts, {acc, off}, fn part, {a, o} -> walk_seg(part, o, a) end)
  end

  defp walk_seg(%FileSlice{length: len} = fs, off, acc),
    do: {emit(acc, off, len, {:slice, fs}), off + len}

  defp walk_seg(bin, off, acc) when is_binary(bin),
    do: {emit(acc, off, byte_size(bin), {:bytes, bin}), off + byte_size(bin)}

  defp walk_seg(parts, off, acc) when is_list(parts), do: walk_segments(parts, off, acc)

  # Zero-size runs (empty leaves) are NOT recorded: keeping every segment size > 0 makes
  # abs_offsets strictly increasing and contiguous, so the splice loop always advances.
  defp emit(acc, _off, 0, _provider), do: acc
  defp emit(acc, off, size, provider), do: [%{abs_offset: off, size: size, provider: provider} | acc]
end
