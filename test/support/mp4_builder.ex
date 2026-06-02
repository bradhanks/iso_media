defmodule ISOMedia.Support.MP4Builder do
  @moduledoc """
  Test helper: builds a minimal, structurally-real ISOBMFF binary with an `mdat`
  containing the given chunks (concatenated) and a `moov/trak/mdia/minf/stbl/stco`
  whose offsets point at each chunk's absolute file position. Returns the binary
  plus the expected offsets so tests can verify chunk resolution.
  """

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  defp stco(offsets) do
    entries = for o <- offsets, into: <<>>, do: <<o::32>>
    leaf("stco", <<0, 0, 0, 0, length(offsets)::32, entries::binary>>)
  end

  # moov containing the real stbl path down to stco.
  defp moov(offsets) do
    stbl = container("stbl", stco(offsets))
    minf = container("minf", stbl)
    mdia = container("mdia", minf)
    trak = container("trak", mdia)
    container("moov", trak)
  end

  @doc """
  Build `%{binary: binary, offsets: [int], chunks: [binary], mdat_payload_start: int}`.

  Options:
    * `:moov_position` — `:first` (default, layout `ftyp, moov, mdat`) or `:last`
      (layout `ftyp, mdat, moov`). Use `:last` to make `faststart/1` a real
      relocation rather than a no-op.
  """
  def build(chunks, opts \\ []) when is_list(chunks) and chunks != [] do
    position = Keyword.get(opts, :moov_position, :first)
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # When moov comes first, the chunks sit after ftyp + moov; moov's byte length is
    # independent of the offset *values* (fixed-width entries), so size it with zeros.
    # When moov comes last, the chunks sit immediately after ftyp.
    mdat_payload_start =
      case position do
        :first -> byte_size(ftyp) + byte_size(moov(List.duplicate(0, length(chunks)))) + 8
        :last -> byte_size(ftyp) + 8
      end

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    mdat = leaf("mdat", mdat_payload)

    binary =
      case position do
        :first -> ftyp <> moov(offsets) <> mdat
        :last -> ftyp <> mdat <> moov(offsets)
      end

    %{binary: binary, offsets: offsets, chunks: chunks, mdat_payload_start: mdat_payload_start}
  end
end
