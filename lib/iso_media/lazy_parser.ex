defmodule ISOMedia.LazyParser do
  @moduledoc """
  Parses an ISOBMFF file without loading it entirely into memory.

  Walks the top-level boxes by seeking. Any box that is read into memory (a
  container, or a leaf smaller than the threshold) is parsed by re-running the
  in-memory `ISOMedia.Parser` over its exact bytes with `offset:` set, so its
  structure and absolute `source_offset`s match the eager parser. A leaf payload at
  or above `:lazy_threshold` becomes an `ISOMedia.FileSlice` and is never read.
  """

  alias ISOMedia.{Box, FileSlice, Parser, Registry}
  alias ISOMedia.IO.Raw

  @default_threshold 1_048_576

  @doc """
  Parse `path` lazily into `{:ok, [%Box{}]}` | `{:error, reason}`.

  Options: `:lazy_threshold` (default #{@default_threshold}), `:heuristic`
  (default `false`, applies only to boxes small enough to be read).
  """
  def parse_file(path, opts \\ []) do
    threshold = Keyword.get(opts, :lazy_threshold, @default_threshold)
    heuristic = Keyword.get(opts, :heuristic, false)
    file_size = File.stat!(path).size

    boxes =
      File.open!(path, [:read, :binary, :raw], fn io ->
        parse_level(io, path, 0, file_size, threshold, heuristic)
      end)

    {:ok, boxes}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_level(_io, _path, pos, file_size, _threshold, _heuristic) when pos >= file_size,
    do: []

  defp parse_level(io, path, pos, file_size, threshold, heuristic) do
    {box, next} = parse_one(io, path, pos, file_size, threshold, heuristic)
    [box | parse_level(io, path, next, file_size, threshold, heuristic)]
  end

  defp parse_one(io, path, pos, file_size, threshold, heuristic) do
    <<size::32, type::binary-size(4)>> = Raw.pread!(io, pos, 8, "LazyParser")
    {size_mode, header_len, total_size} = resolve_size(io, pos, size, file_size)
    uuid_len = if type == "uuid", do: 16, else: 0
    validate_box!(pos, header_len, uuid_len, total_size, file_size)
    payload_length = total_size - header_len - uuid_len

    box =
      cond do
        Registry.container?(type) ->
          reparse(io, pos, total_size, heuristic)

        payload_length >= threshold ->
          file_slice_box(%{
            io: io,
            path: path,
            type: type,
            size_mode: size_mode,
            pos: pos,
            header_len: header_len,
            uuid_len: uuid_len,
            payload_length: payload_length,
            total_size: total_size
          })

        true ->
          reparse(io, pos, total_size, heuristic)
      end

    {box, pos + total_size}
  end

  # Re-parse a fully-read box's bytes through the in-memory parser so its structure
  # and absolute offsets are identical to the eager path.
  defp reparse(io, pos, total_size, heuristic) do
    full = Raw.pread!(io, pos, total_size, "LazyParser")
    {:ok, [box]} = Parser.parse(full, offset: pos, heuristic: heuristic)
    box
  end

  defp file_slice_box(%{io: io, pos: pos, header_len: header_len, uuid_len: uuid_len} = c) do
    uuid = if uuid_len == 16, do: Raw.pread!(io, pos + header_len, 16, "LazyParser"), else: nil
    payload_offset = pos + header_len + uuid_len

    %Box{
      type: c.type,
      data: %FileSlice{path: c.path, offset: payload_offset, length: c.payload_length},
      children: [],
      uuid: uuid,
      size_mode: c.size_mode,
      source_offset: pos,
      source_size: c.total_size
    }
  end

  # A leaf at/above the threshold becomes a FileSlice and is never read, so — unlike the
  # eager parser and the reparse path, where an over-long read makes `pread!` raise — a
  # box that lies about its size would otherwise yield a slice past EOF (over-reporting
  # Content-Length, then raising mid-stream). Enforce the same bounds the eager binary
  # match enforces: the header fits and the box fits within the file.
  defp validate_box!(pos, header_len, uuid_len, total_size, file_size) do
    cond do
      total_size < header_len + uuid_len ->
        raise "LazyParser: box at #{pos} declares size #{total_size}, " <>
                "smaller than its #{header_len + uuid_len}-byte header"

      pos + total_size > file_size ->
        raise "LazyParser: box at #{pos} declares size #{total_size}, " <>
                "extending past end of file (#{file_size} bytes)"

      true ->
        :ok
    end
  end

  defp resolve_size(_io, pos, 0, file_size), do: {:eof, 8, file_size - pos}

  defp resolve_size(io, pos, 1, _file_size) do
    <<largesize::64>> = Raw.pread!(io, pos + 8, 8, "LazyParser")
    {:large, 16, largesize}
  end

  defp resolve_size(_io, _pos, size, _file_size), do: {:compact, 8, size}
end
