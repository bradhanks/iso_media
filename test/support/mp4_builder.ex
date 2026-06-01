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
  """
  def build(chunks) when is_list(chunks) and chunks != [] do
    ftyp = leaf("ftyp", <<"isom", 0::32, "isom">>)
    mdat_payload = IO.iodata_to_binary(chunks)

    # moov byte length is independent of the offset *values* (fixed 32-bit entries),
    # so size it once with zeros, then place real offsets.
    zeros = List.duplicate(0, length(chunks))
    mdat_payload_start = byte_size(ftyp) + byte_size(moov(zeros)) + 8

    {offsets, _} =
      Enum.map_reduce(chunks, mdat_payload_start, fn c, pos -> {pos, pos + byte_size(c)} end)

    mdat = leaf("mdat", mdat_payload)
    binary = ftyp <> moov(offsets) <> mdat

    %{binary: binary, offsets: offsets, chunks: chunks, mdat_payload_start: mdat_payload_start}
  end
end
