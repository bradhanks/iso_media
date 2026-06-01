defmodule ISOMedia.Serializer do
  @moduledoc "Serializes `ISOMedia.Box` trees back into ISOBMFF binary."

  alias ISOMedia.Box
  alias ISOMedia.FileSlice

  @doc "Serialize a box or list of boxes to a binary (materializes any FileSlice payloads)."
  def serialize(boxes), do: boxes |> materialize() |> to_iodata() |> IO.iodata_to_binary()

  @doc "Replace every FileSlice leaf payload in the tree with its on-disk bytes."
  def materialize(%Box{} = box), do: materialize_box(box)
  def materialize(boxes) when is_list(boxes), do: Enum.map(boxes, &materialize_box/1)

  defp materialize_box(%Box{data: %FileSlice{} = slice} = box), do: %{box | data: FileSlice.read(slice)}

  defp materialize_box(%Box{data: nil, children: children} = box),
    do: %{box | children: Enum.map(children, &materialize_box/1)}

  defp materialize_box(%Box{} = box), do: box

  @doc "Serialize a box or list of boxes to iodata (no full-binary materialization)."
  def to_iodata(%Box{} = box), do: to_iodata([box])
  def to_iodata(boxes) when is_list(boxes), do: Enum.map(boxes, &encode_box/1)

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

  defp encode_payload(%Box{data: %FileSlice{}}) do
    raise ArgumentError,
          "box payload is an unread FileSlice; use ISOMedia.write/2 to stream it, " <>
            "or ISOMedia.serialize/1 to materialize it into memory"
  end

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
