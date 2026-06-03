defmodule ISOMedia.Boxes.TrackFragmentHeader do
  @moduledoc "Typed view of the `tfhd` Track Fragment Header box."
  import Bitwise
  alias ISOMedia.{Box, FullBox}

  defstruct [
    :track_id,
    :base_data_offset,
    :sample_description_index,
    :default_sample_duration,
    :default_sample_size,
    :default_sample_flags,
    :default_base_is_moof?
  ]

  @base_data_offset 0x000001
  @sample_desc_index 0x000002
  @default_duration 0x000008
  @default_size 0x000010
  @default_flags 0x000020
  @default_base_is_moof 0x020000

  @doc "Decode a `tfhd` box (only flag-present optional fields are read)."
  def decode(%Box{type: "tfhd", data: data}) do
    {_v, <<flags::24>>, <<track_id::32, rest::binary>>} = FullBox.parse(data)
    {bdo, rest} = take(rest, flags, @base_data_offset, 64)
    {sdi, rest} = take(rest, flags, @sample_desc_index, 32)
    {dur, rest} = take(rest, flags, @default_duration, 32)
    {size, rest} = take(rest, flags, @default_size, 32)
    {dflags, _rest} = take(rest, flags, @default_flags, 32)

    %__MODULE__{
      track_id: track_id,
      base_data_offset: bdo,
      sample_description_index: sdi,
      default_sample_duration: dur,
      default_sample_size: size,
      default_sample_flags: dflags,
      default_base_is_moof?: (flags &&& @default_base_is_moof) != 0
    }
  end

  defp take(bin, flags, mask, bits) do
    if (flags &&& mask) != 0 do
      <<v::size(bits), rest::binary>> = bin
      {v, rest}
    else
      {nil, bin}
    end
  end
end
