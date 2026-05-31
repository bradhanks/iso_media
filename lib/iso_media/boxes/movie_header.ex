defmodule ISOMedia.Boxes.MovieHeader do
  @moduledoc """
  Typed view of the `mvhd` Movie Header Box. Exposes `timescale`/`duration`
  (and creation/modification times); all trailing fields (rate, volume, matrix,
  next_track_ID, ...) are preserved verbatim in `rest`.
  """

  alias ISOMedia.{Box, FullBox}

  defstruct [:version, :flags, :creation_time, :modification_time, :timescale, :duration, :rest]

  def decode(%Box{type: "mvhd", data: data}) do
    {version, flags, body} = FullBox.parse(data)
    {ctime, mtime, timescale, duration, rest} = split(version, body)

    %__MODULE__{
      version: version,
      flags: flags,
      creation_time: ctime,
      modification_time: mtime,
      timescale: timescale,
      duration: duration,
      rest: rest
    }
  end

  def encode(%__MODULE__{version: 0} = h) do
    body = [<<h.creation_time::32, h.modification_time::32, h.timescale::32, h.duration::32>>, h.rest]
    wrap(h, body)
  end

  def encode(%__MODULE__{version: 1} = h) do
    body = [<<h.creation_time::64, h.modification_time::64, h.timescale::32, h.duration::64>>, h.rest]
    wrap(h, body)
  end

  defp split(0, <<c::32, m::32, ts::32, d::32, rest::binary>>), do: {c, m, ts, d, rest}
  defp split(1, <<c::64, m::64, ts::32, d::64, rest::binary>>), do: {c, m, ts, d, rest}

  defp wrap(h, body) do
    %Box{type: "mvhd", data: IO.iodata_to_binary(FullBox.encode(h.version, h.flags, body))}
  end
end
