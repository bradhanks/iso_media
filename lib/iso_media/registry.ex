defmodule ISOMedia.Registry do
  @moduledoc "Classifies which box types are containers (hold child boxes)."

  @containers ~w(
    moov trak mdia minf stbl dinf edts udta mvex moof traf
    mfra meco strk sinf schi
  )

  @doc "True when `type` is a known container box type."
  def container?(type) when is_binary(type), do: type in @containers

  @doc """
  Best-effort: does `payload` look like a clean sequence of child boxes?
  Only compact (32-bit) sizes are considered. Used by the opt-in heuristic.
  """
  def looks_like_boxes?(payload) when is_binary(payload) and byte_size(payload) >= 8 do
    scan(payload)
  end

  def looks_like_boxes?(_), do: false

  defp scan(<<>>), do: true

  defp scan(<<size::32, type::binary-size(4), rest::binary>>)
       when size >= 8 and byte_size(rest) >= size - 8 do
    if printable_type?(type) do
      payload_len = size - 8
      <<_payload::binary-size(payload_len), remainder::binary>> = rest
      scan(remainder)
    else
      false
    end
  end

  defp scan(_), do: false

  defp printable_type?(type) do
    type |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))
  end
end
