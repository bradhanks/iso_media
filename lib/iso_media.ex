defmodule ISOMedia do
  @moduledoc """
  Lossless ISOBMFF (MP4/MOV/M4A/HEIF) box surgery in pure Elixir.

  Parse any ISO Base Media file into a tree of `ISOMedia.Box` structs (every box,
  including unknown/vendor boxes, preserved byte-for-byte), edit it, and re-serialize.
  The invariant throughout is `serialize(parse(file)) == file`.

  This module is the top-level entry point:

    * Read/write — `read/2` (with `lazy: true` for files larger than RAM), `write/2`,
      `parse/2`, `serialize/1`.
    * Arrange — `faststart/1`, `fix_chunk_offsets/1`.
    * Sample-level — `track_ids/1`, `samples/2` (progressive or fragmented),
      `extract_track/2`, `trim/3`, `concat/1`.
    * Fragmented MP4 — `fragment/2` (progressive → fMP4) and `defragment/1` (fMP4 →
      progressive), inverses of each other.

  `trim`, `extract_track`, `concat`, `fragment`, and `defragment` outputs can be chained
  in memory (no disk round-trip); `faststart/1`/`fix_chunk_offsets/1` require an original
  parsed `mdat` and raise on a synthesized one.

      iex> {:ok, boxes} = ISOMedia.parse(<<8::32, "free">>)
      iex> ISOMedia.serialize(boxes)
      <<8::32, "free">>
  """

  alias ISOMedia.{Parser, Serializer}

  @type tree :: [ISOMedia.Box.t()]

  @doc "Parse a binary into `{:ok, [%ISOMedia.Box{}]}`. See `ISOMedia.Parser.parse/2`."
  @spec parse(binary(), keyword()) :: {:ok, tree()} | {:error, String.t()}
  def parse(binary, opts \\ []), do: Parser.parse(binary, opts)

  @doc "Serialize a box or list of boxes back to a binary."
  @spec serialize(tree()) :: binary()
  def serialize(boxes), do: Serializer.serialize(boxes)

  @doc "List the `track_id`s present in the movie."
  @spec track_ids(tree()) :: [pos_integer()]
  def track_ids(boxes), do: ISOMedia.Extract.track_ids(boxes)

  @doc "Decode a track's sample tables into `[%ISOMedia.Sample{}]` (progressive or fragmented)."
  @spec samples(tree(), pos_integer()) :: [ISOMedia.Sample.t()]
  def samples(boxes, track_id) do
    if ISOMedia.FragmentIndex.fragmented?(boxes) do
      ISOMedia.FragmentIndex.samples(boxes, track_id)
    else
      case ISOMedia.Extract.find_trak(boxes, track_id) do
        nil -> raise ArgumentError, "no track with track_id #{track_id}"
        trak -> ISOMedia.SampleTable.build(trak)
      end
    end
  end

  @doc "Extract a single track into a new box tree (then `write/2` or `serialize/1`)."
  @spec extract_track(tree(), pos_integer()) :: tree()
  def extract_track(boxes, track_id), do: ISOMedia.Extract.extract_track(boxes, track_id)

  @doc "Losslessly trim every track to the time range `[start_sec, end_sec)`."
  @spec trim(tree(), number(), number()) :: tree()
  def trim(boxes, start_sec, end_sec), do: ISOMedia.Trim.trim(boxes, start_sec, end_sec)

  @doc "Losslessly concatenate compatible clips end-to-end. See `ISOMedia.Concat.concat/1`."
  @spec concat([tree()]) :: tree()
  def concat(inputs) when is_list(inputs), do: ISOMedia.Concat.concat(inputs)

  @doc "Defragment a fragmented MP4 tree into a progressive one. See `ISOMedia.Defragment.defragment/1`."
  @spec defragment(tree()) :: tree()
  def defragment(boxes), do: ISOMedia.Defragment.defragment(boxes)

  @doc "Repack a progressive tree into a multiplexed fragmented MP4. See `ISOMedia.Fragment.fragment/2`."
  @spec fragment(tree(), keyword()) :: tree()
  def fragment(boxes, opts \\ []), do: ISOMedia.Fragment.fragment(boxes, opts)

  @doc "Split a fragmented tree into a CMAF init segment + media segments. See `ISOMedia.Segment.split/1`."
  @spec split_segments(tree()) :: %{init: tree(), segments: [tree()]}
  def split_segments(boxes), do: ISOMedia.Segment.split(boxes)

  @doc "Write a fragmented tree's init + media segment files into `dir`. See `ISOMedia.Segment.write_segments/3`."
  @spec write_segments(Path.t(), tree(), keyword()) :: {:ok, [Path.t()]} | {:error, term()}
  def write_segments(dir, boxes, opts \\ []),
    do: ISOMedia.Segment.write_segments(dir, boxes, opts)

  @doc "Generate the HLS media playlist (`.m3u8`) for a fragmented tree. See `ISOMedia.HLS.media_playlist/2`."
  @spec hls_media_playlist(tree(), keyword()) :: String.t()
  def hls_media_playlist(boxes, opts \\ []), do: ISOMedia.HLS.media_playlist(boxes, opts)

  @doc "Decode a track's codec + media metadata into `%ISOMedia.TrackInfo{}`. See `ISOMedia.Codec.info/1`."
  @spec track_info(tree(), pos_integer()) :: ISOMedia.TrackInfo.t()
  def track_info(boxes, track_id) do
    case ISOMedia.Extract.find_trak(boxes, track_id) do
      nil -> raise ArgumentError, "track_info: no track with track_id #{track_id}"
      trak -> ISOMedia.Codec.info(trak)
    end
  end

  @doc "Recompute stco/co64 chunk offsets for the current box arrangement. See `ISOMedia.Offsets.fix_chunk_offsets/1`."
  @spec fix_chunk_offsets(tree()) :: tree()
  def fix_chunk_offsets(boxes), do: ISOMedia.Offsets.fix_chunk_offsets(boxes)

  @doc "Move `moov` before `mdat` (faststart) and fix chunk offsets. See `ISOMedia.Offsets.faststart/1`."
  @spec faststart(tree()) :: tree()
  def faststart(boxes), do: ISOMedia.Offsets.faststart(boxes)

  @doc """
  Read a file and parse it. Pass `lazy: true` to keep large leaf payloads
  (≥ `:lazy_threshold`, default 1 MB) as `ISOMedia.FileSlice` references instead of
  loading them, so files larger than memory can be processed.
  """
  @spec read(Path.t(), keyword()) :: {:ok, tree()} | {:error, term()}
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
  @spec write(Path.t(), tree()) :: :ok | {:error, File.posix()}
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

  defp collect_slice_paths(%ISOMedia.Box{data: parts}) when is_list(parts),
    do: slice_paths_in(parts)

  defp collect_slice_paths(%ISOMedia.Box{data: nil, children: children}),
    do: collect_slice_paths(children)

  defp collect_slice_paths(%ISOMedia.Box{}), do: []

  defp slice_paths_in(parts) do
    Enum.flat_map(parts, fn
      %ISOMedia.FileSlice{path: p} -> [p]
      bin when is_binary(bin) -> []
      nested when is_list(nested) -> slice_paths_in(nested)
    end)
  end
end
