defmodule ISOMedia.FileSlice do
  @moduledoc """
  An inert reference to a byte range on disk: `%FileSlice{path, offset, length}`.

  A leaf box may carry a `FileSlice` as its `data` instead of an in-memory binary,
  so bulk payloads (notably `mdat`) are never loaded into memory. The bytes are read
  or streamed on demand; nothing here holds an open file handle.
  """

  alias ISOMedia.IO.Raw

  defstruct [:path, :offset, :length]

  @type t :: %__MODULE__{
          path: Path.t(),
          offset: non_neg_integer(),
          length: non_neg_integer()
        }

  @doc "Read the slice's bytes into a binary (opens, preads, closes)."
  def read(%__MODULE__{path: path, offset: offset, length: length}) do
    File.open!(path, [:read, :binary, :raw], fn io ->
      Raw.pread!(io, offset, length, "FileSlice.read of #{path}")
    end)
  end

  @doc """
  Read `len` bytes starting `rel` bytes into the slice (a bounded sub-range of the
  slice). Opens/preads/closes like `read/1`, so it never holds a file handle. The
  `rel + len <= length` guard makes an out-of-bounds request a contract violation,
  not a silent short read.
  """
  def read_range(%__MODULE__{path: path, offset: offset, length: length}, rel, len)
      when is_integer(rel) and rel >= 0 and is_integer(len) and len >= 0 and rel + len <= length do
    File.open!(path, [:read, :binary, :raw], fn io ->
      Raw.pread!(io, offset + rel, len, "FileSlice.read_range of #{path}")
    end)
  end

  @doc """
  Stream the slice's bytes to an already-open (raw) `io_device` in `chunk_size`
  chunks. The source is opened once (callback form, so it closes even if a write
  raises) and read sequentially.
  """
  def stream(
        %__MODULE__{path: path, offset: offset, length: length},
        io_device,
        chunk_size \\ 65_536
      ) do
    File.open!(path, [:read, :binary, :raw], fn src ->
      stream_chunks(src, io_device, path, offset, length, chunk_size)
    end)
  end

  defp stream_chunks(_src, _dest, _path, _offset, 0, _chunk), do: :ok

  defp stream_chunks(src, dest, path, offset, remaining, chunk) do
    n = min(remaining, chunk)
    label = "FileSlice.stream of #{path}"
    data = Raw.pread!(src, offset, n, label)
    Raw.write!(dest, data, label)
    stream_chunks(src, dest, path, offset + n, remaining - n, chunk)
  end
end
