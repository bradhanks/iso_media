defmodule ISOMedia.SeekIndex do
  @moduledoc """
  A random-access index over a box tree's would-be `serialize/1` output.

  `build/1` flattens the tree (mirroring `ISOMedia.Serializer`) into an offset-ordered
  tuple of physical segments `%{abs_offset, size, provider}`, where
  `provider :: {:bytes, binary} | {:slice, ISOMedia.FileSlice.t()}`. `read_range/3` and
  `stream_range/4` resolve any byte range against the index, reading only the disk bytes
  the range touches. Build once, query many times. The index is opaque.
  """

  alias ISOMedia.{Box, FileSlice, Payload, Serializer}
  alias ISOMedia.IO.Raw

  defstruct [:segments, :count, :byte_size]

  @type t :: %__MODULE__{
          segments: tuple(),
          count: non_neg_integer(),
          byte_size: non_neg_integer()
        }

  @doc "Build the index from a `%Box{}` or list of boxes (same shapes `serialize/1` accepts)."
  def build(%Box{} = box), do: build([box])

  def build(boxes) when is_list(boxes) do
    {rev, total} = walk(boxes, 0, [])
    segments = rev |> Enum.reverse() |> List.to_tuple()
    %__MODULE__{segments: segments, count: tuple_size(segments), byte_size: total}
  end

  @doc "Total size of the serialized output (the HTTP `Content-Length`); reads no payload bytes."
  def content_length(%__MODULE__{byte_size: bs}), do: bs

  @doc """
  Return bytes `[offset, offset+length)` of the serialized output. Clamps to the output
  bounds (a read past EOF returns the available tail, not an error — HTTP-Range friendly).
  Raises `ArgumentError` on a negative or non-integer `offset`/`length` (the public boundary
  is fed untrusted HTTP `Range` values; bad input must fail fast, never reach the splice math).
  """
  def read_range(%__MODULE__{} = idx, offset, length)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 do
    {start, finish} = clamp_range(offset, length, idx.byte_size)

    if finish == start do
      <<>>
    else
      i = bsearch(idx.segments, idx.count, start)
      idx.segments |> splice(i, start, finish, []) |> IO.iodata_to_binary()
    end
  end

  def read_range(%__MODULE__{}, offset, length) do
    raise ArgumentError,
          "read_range/3 offset and length must be non-negative integers, got: #{inspect({offset, length})}"
  end

  # Canonical clamp — the ONE definition the test oracle is also derived from.
  defp clamp_range(offset, length, bs), do: {min(offset, bs), min(offset + length, bs)}

  # Largest index i with segments[i].abs_offset <= target. Only called when start < byte_size,
  # so count >= 1 and segments[0].abs_offset == 0 <= target, giving a valid i in [0, count-1].
  defp bsearch(segments, count, target), do: bsearch(segments, target, 0, count - 1)

  defp bsearch(_segments, _target, lo, hi) when lo >= hi, do: lo

  defp bsearch(segments, target, lo, hi) do
    mid = div(lo + hi + 1, 2)

    if elem(segments, mid).abs_offset <= target,
      do: bsearch(segments, target, mid, hi),
      else: bsearch(segments, target, lo, mid - 1)
  end

  # Walk forward from segment i, slicing each segment's overlap with [pos, finish).
  defp splice(_segments, _i, pos, finish, acc) when pos >= finish, do: Enum.reverse(acc)

  defp splice(segments, i, pos, finish, acc) do
    seg = elem(segments, i)
    seg_hi = seg.abs_offset + seg.size
    take_hi = min(finish, seg_hi)
    rel = pos - seg.abs_offset
    chunk = read_provider(seg.provider, rel, take_hi - pos)
    splice(segments, i + 1, take_hi, finish, [chunk | acc])
  end

  defp read_provider({:bytes, bin}, rel, n), do: :binary.part(bin, rel, n)
  defp read_provider({:slice, fs}, rel, n), do: FileSlice.read_range(fs, rel, n)

  @doc """
  Lazily stream bytes `[offset, offset+length)` as a `Stream` of `chunk_size`-byte binaries.
  Memory-safe for large `FileSlice`-backed ranges; the underlying file is opened once per
  touched slice (not per chunk) and closed deterministically on halt, error, or completion
  via `Stream.resource/3`'s `after_fun`. Same input guards as `read_range/3`.
  """
  def stream_range(idx, offset, length, chunk_size \\ 65_536)

  def stream_range(%__MODULE__{} = idx, offset, length, chunk_size)
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 0 and
             is_integer(chunk_size) and chunk_size > 0 do
    {start, finish} = clamp_range(offset, length, idx.byte_size)

    Stream.resource(
      fn -> %{pos: start, fd: nil} end,
      fn state -> stream_next(state, idx, finish, chunk_size) end,
      fn state -> close_fd(state) end
    )
  end

  def stream_range(%__MODULE__{}, offset, length, _chunk_size) do
    raise ArgumentError,
          "stream_range/4 offset and length must be non-negative integers, got: #{inspect({offset, length})}"
  end

  defp stream_next(%{pos: pos} = state, _idx, finish, _chunk) when pos >= finish do
    {:halt, state}
  end

  defp stream_next(%{pos: pos} = state, idx, finish, chunk_size) do
    seg = elem(idx.segments, bsearch(idx.segments, idx.count, pos))
    seg_hi = seg.abs_offset + seg.size
    take_hi = Enum.min([finish, seg_hi, pos + chunk_size])
    rel = pos - seg.abs_offset
    n = take_hi - pos

    case seg.provider do
      {:bytes, bin} ->
        {[:binary.part(bin, rel, n)], %{close_fd(state) | pos: take_hi}}

      {:slice, fs} ->
        {io, state} = ensure_open(state, fs)
        {[Raw.pread!(io, fs.offset + rel, n, "SeekIndex.stream_range")], %{state | pos: take_hi}}
    end
  end

  # Keep the same fd open across consecutive chunks of one FileSlice; reopen on slice change.
  defp ensure_open(%{fd: {fs, io}} = state, fs), do: {io, state}

  defp ensure_open(state, fs) do
    state = close_fd(state)
    io = File.open!(fs.path, [:read, :binary, :raw])
    {io, %{state | fd: {fs, io}}}
  end

  defp close_fd(%{fd: nil} = state), do: state

  defp close_fd(%{fd: {_fs, io}} = state) do
    File.close(io)
    %{state | fd: nil}
  end

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

  # leaf: flatten the payload into its physical leaves (Payload owns the segment-list
  # recursion), then tag each with a provider and lay it out at an absolute offset.
  defp walk_payload(%Box{data: data}, off, acc) do
    Enum.reduce(Payload.flatten(data), {acc, off}, fn leaf, {a, o} ->
      size = Payload.size(leaf)
      {emit(a, o, size, provider(leaf)), o + size}
    end)
  end

  defp provider(%FileSlice{} = fs), do: {:slice, fs}
  defp provider(bin) when is_binary(bin), do: {:bytes, bin}

  # Zero-size runs (empty leaves) are NOT recorded: keeping every segment size > 0 makes
  # abs_offsets strictly increasing and contiguous, so the splice loop always advances.
  defp emit(acc, _off, 0, _provider), do: acc

  defp emit(acc, off, size, provider),
    do: [%{abs_offset: off, size: size, provider: provider} | acc]
end
