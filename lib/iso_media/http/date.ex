defmodule ISOMedia.HTTP.Date do
  @moduledoc """
  HTTP-date parsing and formatting (RFC 7231 §7.1.1.1).

  `parse/1` accepts the preferred IMF-fixdate plus the two obsolete formats
  (RFC 850, asctime), returning a `:calendar.datetime()` (UTC) or `:error`.
  `format/1` always emits IMF-fixdate.
  """

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @imf ~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @rfc850 ~r/^\w+, (\d{2})-(\w{3})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) GMT$/
  @asctime ~r/^\w{3} (\w{3})\s+(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$/

  @spec parse(binary()) :: {:ok, :calendar.datetime()} | :error
  def parse(str) when is_binary(str) do
    s = String.trim(str)

    cond do
      m = Regex.run(@imf, s) ->
        [_, d, mon, y, h, mi, sec] = m
        build(y, mon, d, h, mi, sec)

      m = Regex.run(@rfc850, s) ->
        [_, d, mon, yy, h, mi, sec] = m
        build(rfc850_year(yy), mon, d, h, mi, sec)

      m = Regex.run(@asctime, s) ->
        [_, mon, d, h, mi, sec, y] = m
        build(y, mon, d, h, mi, sec)

      true ->
        :error
    end
  end

  def parse(_), do: :error

  @spec format(:calendar.datetime()) :: binary()
  def format({{y, mo, d}, {h, mi, s}}) do
    dow = :calendar.day_of_the_week(y, mo, d)

    "#{Enum.at(@days, dow - 1)}, #{pad(d)} #{Enum.at(@months, mo - 1)} #{y} " <>
      "#{pad(h)}:#{pad(mi)}:#{pad(s)} GMT"
  end

  # RFC 850 two-digit year: 0-69 => 2000s, 70-99 => 1900s.
  defp rfc850_year(yy) do
    n = String.to_integer(yy)
    if n < 70, do: Integer.to_string(2000 + n), else: Integer.to_string(1900 + n)
  end

  defp build(y, mon, d, h, mi, sec) do
    with idx when is_integer(idx) <- Enum.find_index(@months, &(&1 == mon)),
         dt = {{int(y), idx + 1, int(d)}, {int(h), int(mi), int(sec)}},
         true <- :calendar.valid_date(elem(dt, 0)) do
      {:ok, dt}
    else
      _ -> :error
    end
  end

  defp int(s), do: String.to_integer(s)
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
