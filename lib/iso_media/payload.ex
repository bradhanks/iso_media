defmodule ISOMedia.Payload do
  @moduledoc """
  Operations over a leaf box's payload, in whatever form it currently takes.

  A leaf's `data` is one of three shapes, and this module is the single place that
  knows how to dispatch over them:

    * a `binary` — bytes already in memory;
    * an `ISOMedia.FileSlice` — a `{path, offset, length}` reference to bytes on disk;
    * a (possibly nested) `[segment]` list — a recursive segment list whose parts are
      themselves binaries, `FileSlice`s, or further segment lists.

  Containers (`data: nil` + children) are **not** payloads — callers keep an explicit
  `data == nil` branch and only delegate the leaf case here. Every payload operation the
  rest of the library needs (`size/1`, `read/1`, `stream/3`, `slice/3`, `slice_paths/1`)
  lives here, so adding a new payload representation is a one-file change rather than a
  hunt through `Layout`, `Serializer`, `MdatSource`, and friends.
  """

  alias ISOMedia.FileSlice

  @typedoc "A single segment: in-memory bytes, an on-disk slice, or a nested segment list."
  @type segment :: binary() | FileSlice.t() | [segment()]

  @typedoc "A leaf payload: a binary, a FileSlice, or a (possibly nested) segment list."
  @type t :: binary() | FileSlice.t() | [segment()]

  @doc "Total serialized byte length of a payload, reading no payload bytes."
  @spec size(t()) :: non_neg_integer()
  def size(%FileSlice{length: len}), do: len
  def size(bin) when is_binary(bin), do: byte_size(bin)
  def size(parts) when is_list(parts), do: Enum.sum(Enum.map(parts, &size/1))

  @doc "Read a payload into a single in-memory binary (preads any FileSlice parts)."
  @spec read(t()) :: binary()
  def read(%FileSlice{} = slice), do: FileSlice.read(slice)
  def read(bin) when is_binary(bin), do: bin
  def read(parts) when is_list(parts), do: parts |> Enum.map(&read/1) |> IO.iodata_to_binary()

  @doc """
  Stream a payload to an already-open raw `io_device`, reading any `FileSlice` parts
  from disk in `chunk_size`-byte chunks so a multi-GB payload is never materialized.
  """
  @spec stream(t(), :file.io_device(), pos_integer()) :: :ok
  def stream(%FileSlice{} = slice, io, chunk), do: FileSlice.stream(slice, io, chunk)
  def stream(bin, io, _chunk) when is_binary(bin), do: write!(io, bin)
  def stream(parts, io, chunk) when is_list(parts), do: Enum.each(parts, &stream(&1, io, chunk))

  @doc """
  Slice the sub-range `[rel, rel+len)` out of a payload, returning a payload of the same
  family: a `FileSlice` window, a `binary_part`, or — when the range spans several parts
  of a segment list — a (sub-)segment list. A single overlapping part is returned bare;
  several are returned as a list. This is what lets one synthesized `mdat` be re-sliced
  to feed the next pipeline stage without touching disk.
  """
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%FileSlice{path: path, offset: base}, rel, len) do
    %FileSlice{path: path, offset: base + rel, length: len}
  end

  def slice(bin, rel, len) when is_binary(bin), do: binary_part(bin, rel, len)
  def slice(parts, rel, len) when is_list(parts), do: slice_segments(parts, rel, len)

  # Walk parts accumulating their byte lengths; slice each part overlapping [lo, lo+len).
  # One overlapping part -> return its slice bare; several -> a list.
  defp slice_segments(parts, lo, len) do
    hi = lo + len

    {slices, _pos} =
      Enum.flat_map_reduce(parts, 0, fn part, pos ->
        part_hi = pos + size(part)

        if part_hi <= lo or pos >= hi do
          {[], part_hi}
        else
          start = max(lo, pos) - pos
          take = min(hi, part_hi) - max(lo, pos)
          {[slice(part, start, take)], part_hi}
        end
      end)

    case slices do
      [one] -> one
      many -> many
    end
  end

  @doc "The on-disk paths a payload references (empty for in-memory bytes)."
  @spec slice_paths(t()) :: [Path.t()]
  def slice_paths(%FileSlice{path: path}), do: [path]
  def slice_paths(bin) when is_binary(bin), do: []
  def slice_paths(parts) when is_list(parts), do: Enum.flat_map(parts, &slice_paths/1)

  defp write!(io, data) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> raise "Payload.stream: write failed: #{:file.format_error(reason)}"
    end
  end
end
