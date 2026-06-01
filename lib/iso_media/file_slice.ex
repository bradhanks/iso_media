defmodule ISOMedia.FileSlice do
  @moduledoc """
  An inert reference to a byte range on disk: `%FileSlice{path, offset, length}`.

  A leaf box may carry a `FileSlice` as its `data` instead of an in-memory binary,
  so bulk payloads (notably `mdat`) are never loaded into memory. The bytes are read
  or streamed on demand; nothing here holds an open file handle.
  """

  defstruct [:path, :offset, :length]

  @type t :: %__MODULE__{
          path: Path.t(),
          offset: non_neg_integer(),
          length: non_neg_integer()
        }

  @doc "Read the slice's bytes into a binary (opens, preads, closes)."
  def read(%__MODULE__{path: path, offset: offset, length: length}) do
    File.open!(path, [:read, :binary, :raw], fn io ->
      case :file.pread(io, offset, length) do
        {:ok, data} when byte_size(data) == length ->
          data

        {:ok, data} ->
          raise "FileSlice.read: short read at #{offset} of #{path}: wanted #{length}, got #{byte_size(data)}"

        :eof ->
          raise "FileSlice.read: unexpected EOF reading #{length} bytes at #{offset} of #{path}"

        {:error, reason} ->
          raise "FileSlice.read: #{:file.format_error(reason)} reading #{length} bytes at #{offset} of #{path}"
      end
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

    case :file.pread(src, offset, n) do
      {:ok, data} when byte_size(data) == n ->
        case :file.write(dest, data) do
          :ok ->
            stream_chunks(src, dest, path, offset + n, remaining - n, chunk)

          {:error, reason} ->
            raise "FileSlice.stream: write failed: #{:file.format_error(reason)}"
        end

      {:ok, data} ->
        raise "FileSlice.stream: short read at #{offset} of #{path}: wanted #{n}, got #{byte_size(data)}"

      :eof ->
        raise "FileSlice.stream: unexpected EOF at #{offset} of #{path}"

      {:error, reason} ->
        raise "FileSlice.stream: #{:file.format_error(reason)} at #{offset} of #{path}"
    end
  end
end
