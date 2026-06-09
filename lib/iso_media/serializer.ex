defmodule ISOMedia.Serializer do
  @moduledoc "Serializes `ISOMedia.Box` trees back into ISOBMFF binary."

  alias ISOMedia.Box
  alias ISOMedia.FileSlice
  alias ISOMedia.IO.Raw
  alias ISOMedia.Layout
  alias ISOMedia.Payload

  @doc "Serialize a box or list of boxes to a binary (materializes any FileSlice payloads)."
  def serialize(boxes), do: boxes |> materialize() |> to_iodata() |> IO.iodata_to_binary()

  @doc "Replace every FileSlice leaf payload in the tree with its on-disk bytes."
  def materialize(%Box{} = box), do: materialize_box(box)
  def materialize(boxes) when is_list(boxes), do: Enum.map(boxes, &materialize_box/1)

  defp materialize_box(%Box{data: nil, children: children} = box),
    do: %{box | children: Enum.map(children, &materialize_box/1)}

  defp materialize_box(%Box{data: data} = box) when is_binary(data), do: box

  defp materialize_box(%Box{data: data} = box), do: %{box | data: Payload.read(data)}

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

  defp encode_payload(%Box{data: parts}) when is_list(parts) do
    raise ArgumentError,
          "box payload is a segment list; use ISOMedia.write/2 to stream it, " <>
            "or ISOMedia.serialize/1 to materialize it into memory"
  end

  defp encode_payload(%Box{data: data}), do: data

  @doc """
  The full pre-payload bytes of a box: the 4/8/16-byte size+type header, followed by
  the 16 `uuid` bytes for an extended-type box. Its length equals `Layout.header_size/1`
  by construction. Exposed so `ISOMedia.SeekIndex` reuses the one header encoder rather
  than duplicating it (the uuid bytes are emitted *after* the header — see `stream_box`).
  """
  def header_bytes(%Box{uuid: uuid} = box) do
    u = uuid || <<>>
    body_len = byte_size(u) + (Layout.box_size(box) - Layout.header_size(box))
    encode_header(box, body_len) <> u
  end

  # compact: total size = 8 (header) + body. Refuse to emit a truncated 32-bit size
  # field — a `:compact` box whose body overflows must be built as `:large` instead
  # (`<<x::32>>` would silently wrap, corrupting the file). The check reuses the one
  # compact↔large decision in `Box`, so it can never disagree with how builders stamp
  # synthesized boxes.
  defp encode_header(%Box{type: type, size_mode: :compact}, body_len) do
    if Box.size_mode_for_body(body_len) != :compact do
      raise ArgumentError,
            "box #{inspect(type)} has a #{body_len}-byte body that overflows the 32-bit " <>
              "compact size field; build it with size_mode: :large (largesize)"
    end

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

  @doc """
  Stream a box or list of boxes to an open raw `io_device`, reading `FileSlice`
  payloads from disk in `chunk_size`-byte chunks (so a multi-GB payload is never
  held in memory). Returns `:ok`.
  """
  def stream(boxes, io_device, chunk_size \\ 65_536)
  def stream(%Box{} = box, io_device, chunk_size), do: stream([box], io_device, chunk_size)

  def stream(boxes, io_device, chunk_size) when is_list(boxes) do
    Enum.each(boxes, &stream_box(&1, io_device, chunk_size))
  end

  defp stream_box(%Box{data: data, children: [_ | _]}, _io, _chunk) when not is_nil(data) do
    raise ArgumentError,
          "invalid box: has both data and children (cannot serialize unambiguously)"
  end

  defp stream_box(%Box{} = box, io, chunk_size) do
    uuid = box.uuid || <<>>
    # body = uuid ++ payload; body length is derivable from Layout without reading.
    body_len = byte_size(uuid) + (Layout.box_size(box) - Layout.header_size(box))
    Raw.write!(io, encode_header(box, body_len), "Serializer.stream")
    Raw.write!(io, uuid, "Serializer.stream")
    stream_payload(box, io, chunk_size)
  end

  defp stream_payload(%Box{data: nil, children: children}, io, chunk),
    do: Enum.each(children, &stream_box(&1, io, chunk))

  defp stream_payload(%Box{data: data}, io, chunk), do: Payload.stream(data, io, chunk)
end
