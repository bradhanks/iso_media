defmodule ISOMedia.Serializer do
  @moduledoc "Serializes `ISOMedia.Box` trees back into ISOBMFF binary."

  alias ISOMedia.Box

  @doc "Serialize a box or list of boxes to a binary."
  def serialize(%Box{} = box), do: serialize([box])

  def serialize(boxes) when is_list(boxes) do
    boxes |> Enum.map(&encode_box/1) |> IO.iodata_to_binary()
  end

  defp encode_box(%Box{} = box) do
    body = [box.uuid || <<>>, encode_payload(box)]
    body_len = IO.iodata_length(body)
    [encode_header(box, body_len), body]
  end

  defp encode_payload(%Box{data: data, children: [_ | _]}) when not is_nil(data) do
    raise ArgumentError,
          "invalid box: has both data and children (cannot serialize unambiguously)"
  end

  defp encode_payload(%Box{data: nil, children: children}), do: Enum.map(children, &encode_box/1)
  defp encode_payload(%Box{data: data}), do: data

  # compact: total size = 8 (header) + body
  defp encode_header(%Box{type: type, size_mode: :compact}, body_len) do
    <<8 + body_len::32, type::binary>>
  end

  # large: size field == 1, largesize = 16 (header) + body
  defp encode_header(%Box{type: type, size_mode: :large}, body_len) do
    <<1::32, type::binary, 16 + body_len::64>>
  end

  # eof: size field == 0
  defp encode_header(%Box{type: type, size_mode: :eof}, _body_len) do
    <<0::32, type::binary>>
  end
end
