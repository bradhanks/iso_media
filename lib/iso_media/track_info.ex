defmodule ISOMedia.TrackInfo do
  @moduledoc "Decoded codec + media metadata for one track. See `ISOMedia.track_info/2`."

  @type type :: :video | :audio

  @type t :: %__MODULE__{
          track_id: pos_integer(),
          type: type(),
          format: String.t(),
          codec: String.t(),
          timescale: pos_integer(),
          duration: non_neg_integer(),
          language: String.t(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          sample_rate: pos_integer() | nil,
          channels: pos_integer() | nil
        }

  defstruct [
    :track_id,
    :type,
    :format,
    :codec,
    :timescale,
    :duration,
    :language,
    :width,
    :height,
    :sample_rate,
    :channels
  ]
end
