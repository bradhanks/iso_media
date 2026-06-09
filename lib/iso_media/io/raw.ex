defmodule ISOMedia.IO.Raw do
  @moduledoc """
  Raise-on-error wrappers around raw `:file` reads and writes.

  Lives under the `ISOMedia.IO` namespace — the impure, disk-touching layer — kept a
  rung below the pure core (`Box`, `Layout`, `Parser`, `Serializer`'s iodata path, …).
  Several modules (`FileSlice`, `SeekIndex`, `LazyParser`, `Serializer`, `Payload`)
  pread/write to an already-open raw `io_device` and each used to re-implement the same
  short-read / EOF / posix-error `case`. That handling lives here once; callers pass a
  `label` so the error message still names the caller's context.

  (Named `IO.Raw`, not a bare `ISOMedia.IO`: a top-level `IO` module would shadow
  Elixir's built-in `IO` when aliased, which `Payload`/`Serializer` rely on.)
  """

  @doc """
  Pread exactly `len` bytes at `at` from raw `io`, raising on a short read, EOF, or
  posix error. A zero-length read returns `<<>>` (even at EOF), which boundary ranges
  rely on. `label` prefixes any error message.
  """
  @spec pread!(:file.io_device(), non_neg_integer(), non_neg_integer(), String.t()) :: binary()
  def pread!(io, at, len, label) do
    case :file.pread(io, at, len) do
      {:ok, data} when byte_size(data) == len ->
        data

      :eof when len == 0 ->
        <<>>

      :eof ->
        raise "#{label}: unexpected EOF reading #{len} bytes at #{at}"

      {:ok, data} ->
        raise "#{label}: short read at #{at}: wanted #{len}, got #{byte_size(data)}"

      {:error, reason} ->
        raise "#{label}: #{:file.format_error(reason)} reading #{len} bytes at #{at}"
    end
  end

  @doc "Write `data` to raw `io`, raising on error. `label` prefixes any error message."
  @spec write!(:file.io_device(), iodata(), String.t()) :: :ok
  def write!(io, data, label) do
    case :file.write(io, data) do
      :ok -> :ok
      {:error, reason} -> raise "#{label}: write failed: #{:file.format_error(reason)}"
    end
  end
end
