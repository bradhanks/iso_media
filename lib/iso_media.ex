defmodule ISOMedia do
  @moduledoc """
  Lossless ISOBMFF (MP4/MOV/M4A/HEIF) box surgery.

      iex> {:ok, boxes} = ISOMedia.parse(<<8::32, "free">>)
      iex> ISOMedia.serialize(boxes)
      <<8::32, "free">>
  """

  alias ISOMedia.{Parser, Serializer}

  @doc "Parse a binary into `{:ok, [%ISOMedia.Box{}]}`. See `ISOMedia.Parser.parse/2`."
  def parse(binary, opts \\ []), do: Parser.parse(binary, opts)

  @doc "Serialize a box or list of boxes back to a binary."
  def serialize(boxes), do: Serializer.serialize(boxes)

  @doc "List the `track_id`s present in the movie."
  def track_ids(boxes), do: ISOMedia.Extract.track_ids(boxes)

  @doc "Decode a track's sample tables into `[%ISOMedia.Sample{}]`."
  def samples(boxes, track_id) do
    case ISOMedia.Extract.find_trak(boxes, track_id) do
      nil -> raise ArgumentError, "no track with track_id #{track_id}"
      trak -> ISOMedia.SampleTable.build(trak)
    end
  end

  @doc "Extract a single track into a new box tree (then `write/2` or `serialize/1`)."
  def extract_track(boxes, track_id), do: ISOMedia.Extract.extract_track(boxes, track_id)

  @doc "Losslessly trim every track to the time range `[start_sec, end_sec)`."
  def trim(boxes, start_sec, end_sec), do: ISOMedia.Trim.trim(boxes, start_sec, end_sec)

  @doc "Recompute stco/co64 chunk offsets for the current box arrangement. See `ISOMedia.Offsets.fix_chunk_offsets/1`."
  def fix_chunk_offsets(boxes), do: ISOMedia.Offsets.fix_chunk_offsets(boxes)

  @doc "Move `moov` before `mdat` (faststart) and fix chunk offsets. See `ISOMedia.Offsets.faststart/1`."
  def faststart(boxes), do: ISOMedia.Offsets.faststart(boxes)

  @doc """
  Read a file and parse it. Pass `lazy: true` to keep large leaf payloads
  (≥ `:lazy_threshold`, default 1 MB) as `ISOMedia.FileSlice` references instead of
  loading them, so files larger than memory can be processed.
  """
  def read(path, opts \\ []) do
    if Keyword.get(opts, :lazy, false) do
      ISOMedia.LazyParser.parse_file(path, opts)
    else
      with {:ok, binary} <- File.read(path), do: parse(binary, opts)
    end
  end

  @doc """
  Serialize boxes and write them to `path`, streaming any `FileSlice` payloads
  disk→disk (memory-safe for large files). Raises if `path` is one of the tree's
  `FileSlice` sources (you cannot stream-overwrite the file you are reading).
  """
  def write(path, boxes) do
    check_overwrite!(path, boxes)

    case File.open(path, [:write, :binary, :raw], fn io ->
           ISOMedia.Serializer.stream(boxes, io)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_overwrite!(path, boxes) do
    out_expanded = Path.expand(path)
    out_id = file_id(path)

    boxes
    |> collect_slice_paths()
    |> Enum.uniq()
    |> Enum.each(fn src ->
      cond do
        Path.expand(src) == out_expanded ->
          raise ArgumentError,
                "write/2: output #{path} is also a FileSlice source; write to a different file"

        out_id != nil and out_id == file_id(src) ->
          raise ArgumentError,
                "write/2: output #{path} resolves to the same file as a FileSlice source (#{src}); write to a different file"

        true ->
          :ok
      end
    end)
  end

  defp file_id(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: maj, minor_device: min, inode: ino}} -> {maj, min, ino}
      _ -> nil
    end
  end

  defp collect_slice_paths(boxes) when is_list(boxes),
    do: Enum.flat_map(boxes, &collect_slice_paths/1)

  defp collect_slice_paths(%ISOMedia.Box{data: %ISOMedia.FileSlice{path: p}}), do: [p]

  defp collect_slice_paths(%ISOMedia.Box{data: parts}) when is_list(parts) do
    Enum.flat_map(parts, fn
      %ISOMedia.FileSlice{path: p} -> [p]
      bin when is_binary(bin) -> []
    end)
  end

  defp collect_slice_paths(%ISOMedia.Box{data: nil, children: children}),
    do: collect_slice_paths(children)

  defp collect_slice_paths(%ISOMedia.Box{}), do: []
end
