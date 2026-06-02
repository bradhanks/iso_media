defmodule ISOMedia.Boxes.EditList do
  @moduledoc """
  Typed view of the `elst` Edit List Box (inside `trak` → `edts`).

  Each entry is `%{segment_duration, media_time, rate_integer, rate_fraction}`.
  Timescales differ by field: `segment_duration` is in the **movie** timescale
  (`mvhd`), `media_time` is in the track's **media** timescale (`mdhd`). `media_time`
  is `-1` for an empty edit. Encoding uses version 0 unless a `segment_duration` or
  `media_time` needs 64 bits, in which case version 1.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :entries]

  @type entry :: %{
          segment_duration: non_neg_integer(),
          media_time: integer(),
          rate_integer: integer(),
          rate_fraction: non_neg_integer()
        }

  @type t :: %__MODULE__{version: 0 | 1, entries: [entry()]}

  @uint32_max 0xFFFFFFFF
  @int32_max 0x7FFFFFFF
  @int32_min -0x80000000

  @doc "Decode an `elst` box into a `%EditList{}`."
  def decode(%Box{type: "elst", data: data}) do
    {version, _flags, <<_count::32, rest::binary>>} = FullBox.parse(data)
    %__MODULE__{version: version, entries: decode_entries(version, rest)}
  end

  defp decode_entries(0, bin) do
    for <<seg::32, mt::signed-32, ri::signed-16, rf::16 <- bin>> do
      %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}
    end
  end

  defp decode_entries(1, bin) do
    for <<seg::64, mt::signed-64, ri::signed-16, rf::16 <- bin>> do
      %{segment_duration: seg, media_time: mt, rate_integer: ri, rate_fraction: rf}
    end
  end

  @doc "Encode a `%EditList{}` into an `elst` box (v0, or v1 if a value needs 64 bits)."
  def encode(%__MODULE__{entries: entries}) do
    version = if Enum.any?(entries, &needs_v1?/1), do: 1, else: 0
    body = [<<length(entries)::32>>, Enum.map(entries, &encode_entry(version, &1))]
    %Box{type: "elst", data: IO.iodata_to_binary(FullBox.encode(version, <<0, 0, 0>>, body))}
  end

  defp needs_v1?(%{segment_duration: seg, media_time: mt}) do
    seg > @uint32_max or mt > @int32_max or mt < @int32_min
  end

  defp encode_entry(0, %{
         segment_duration: seg,
         media_time: mt,
         rate_integer: ri,
         rate_fraction: rf
       }) do
    <<seg::32, mt::signed-32, ri::signed-16, rf::16>>
  end

  defp encode_entry(1, %{
         segment_duration: seg,
         media_time: mt,
         rate_integer: ri,
         rate_fraction: rf
       }) do
    <<seg::64, mt::signed-64, ri::signed-16, rf::16>>
  end
end
