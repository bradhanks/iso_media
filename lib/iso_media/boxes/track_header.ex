defmodule ISOMedia.Boxes.TrackHeader do
  @moduledoc """
  Typed view of the `tkhd` Track Header Box. Exposes `track_id`/`duration`
  (and creation/modification times); trailing fields are preserved in `rest`.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :creation_time, :modification_time, :track_id, :duration, :rest]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          flags: <<_::24>>,
          creation_time: non_neg_integer(),
          modification_time: non_neg_integer(),
          track_id: non_neg_integer(),
          duration: non_neg_integer(),
          rest: binary()
        }

  @doc "Decode a `tkhd` box into a `%TrackHeader{}`."
  def decode(%Box{type: "tkhd", data: data}) do
    {version, flags, body} = FullBox.parse(data)
    {ctime, mtime, track_id, duration, rest} = split(version, body)

    %__MODULE__{
      version: version,
      flags: flags,
      creation_time: ctime,
      modification_time: mtime,
      track_id: track_id,
      duration: duration,
      rest: rest
    }
  end

  @doc "Encode a `%TrackHeader{}` back into a `tkhd` box."
  def encode(%__MODULE__{version: 0} = h) do
    body = [
      <<h.creation_time::32, h.modification_time::32, h.track_id::32, 0::32, h.duration::32>>,
      h.rest
    ]

    wrap(h, body)
  end

  def encode(%__MODULE__{version: 1} = h) do
    body = [
      <<h.creation_time::64, h.modification_time::64, h.track_id::32, 0::32, h.duration::64>>,
      h.rest
    ]

    wrap(h, body)
  end

  defp split(0, <<c::32, m::32, id::32, _res::32, d::32, rest::binary>>), do: {c, m, id, d, rest}
  defp split(1, <<c::64, m::64, id::32, _res::32, d::64, rest::binary>>), do: {c, m, id, d, rest}

  defp wrap(h, body) do
    %Box{type: "tkhd", data: FullBox.encode_data(h.version, h.flags, body)}
  end
end
