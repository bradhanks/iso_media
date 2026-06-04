defmodule ISOMedia.Timescale do
  @moduledoc "Integer timescale rescaling shared across editing operations."

  @doc "Rescale `value` from `from_ts` to `to_ts` (integer, round-half-up; no float precision loss)."
  def scale(value, from_ts, to_ts), do: div(value * to_ts + div(from_ts, 2), from_ts)
end
