defmodule ISOMedia.Boxes.TrackExtends do
  @moduledoc "Typed view of the `trex` Track Extends box (inside `moov` → `mvex`)."
  alias ISOMedia.{Box, FullBox}

  defstruct [
    :track_id,
    :default_sample_description_index,
    :default_sample_duration,
    :default_sample_size,
    :default_sample_flags
  ]

  @doc "Decode a `trex` box."
  def decode(%Box{type: "trex", data: data}) do
    {_v, _f, <<track_id::32, dsdi::32, dur::32, size::32, flags::32>>} = FullBox.parse(data)

    %__MODULE__{
      track_id: track_id,
      default_sample_description_index: dsdi,
      default_sample_duration: dur,
      default_sample_size: size,
      default_sample_flags: flags
    }
  end
end
