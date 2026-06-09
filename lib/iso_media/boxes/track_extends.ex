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

  @type t :: %__MODULE__{
          track_id: non_neg_integer(),
          default_sample_description_index: non_neg_integer(),
          default_sample_duration: non_neg_integer(),
          default_sample_size: non_neg_integer(),
          default_sample_flags: non_neg_integer()
        }

  @doc "Decode a `trex` box."
  @spec decode(ISOMedia.Box.t()) :: t()
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

  @doc "Encode a `%TrackExtends{}` back into a `trex` box."
  @spec encode(t()) :: ISOMedia.Box.t()
  def encode(%__MODULE__{} = t) do
    body =
      <<t.track_id::32, t.default_sample_description_index::32, t.default_sample_duration::32,
        t.default_sample_size::32, t.default_sample_flags::32>>

    %Box{type: "trex", data: FullBox.encode_data(0, <<0, 0, 0>>, body)}
  end
end
