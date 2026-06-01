defmodule ISOMedia.Parser do
  @moduledoc "Decodes an ISOBMFF binary into a list of `ISOMedia.Box` structs."

  alias ISOMedia.{Box, Registry}

  @doc """
  Parse `binary` into `{:ok, [%Box{}]}`, or `{:error, reason}` on malformed input.

  Options:
    * `:heuristic` (default `false`) — sniff unknown box types for nested boxes.
    * `:offset` (default `0`) — absolute byte offset the binary begins at; threaded
      into every box's `source_offset` so they are absolute even when parsing a slice.
  """
  def parse(binary, opts \\ []) when is_binary(binary) do
    {:ok, parse_boxes(binary, opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_boxes(binary, opts), do: parse_boxes(binary, opts, Keyword.get(opts, :offset, 0))

  defp parse_boxes(<<>>, _opts, _offset), do: []

  defp parse_boxes(binary, opts, offset) do
    {box, rest} = parse_box(binary, opts, offset)
    [box | parse_boxes(rest, opts, offset + box.source_size)]
  end

  defp parse_box(<<size::32, type::binary-size(4), after_type::binary>> = full, opts, offset) do
    {size_mode, payload, remainder} = take_payload(size, after_type)
    {uuid, payload} = take_uuid(type, payload)
    box_size = byte_size(full) - byte_size(remainder)
    payload_offset = offset + (box_size - byte_size(payload))

    box =
      if container?(type, payload, opts) do
        %Box{
          type: type,
          data: nil,
          children: parse_boxes(payload, opts, payload_offset),
          uuid: uuid,
          size_mode: size_mode,
          source_offset: offset,
          source_size: box_size
        }
      else
        %Box{
          type: type,
          data: payload,
          children: [],
          uuid: uuid,
          size_mode: size_mode,
          source_offset: offset,
          source_size: box_size
        }
      end

    {box, remainder}
  end

  # size == 1 → 64-bit largesize follows (header is 16 bytes total)
  defp take_payload(1, <<largesize::64, rest::binary>>) do
    payload_len = largesize - 16
    <<payload::binary-size(payload_len), remainder::binary>> = rest
    {:large, payload, remainder}
  end

  # size == 0 → box runs to end of input
  defp take_payload(0, rest), do: {:eof, rest, <<>>}

  # normal 32-bit size (header is 8 bytes)
  defp take_payload(size, rest) do
    payload_len = size - 8
    <<payload::binary-size(payload_len), remainder::binary>> = rest
    {:compact, payload, remainder}
  end

  defp take_uuid("uuid", <<uuid::binary-size(16), payload::binary>>), do: {uuid, payload}
  defp take_uuid(_type, payload), do: {nil, payload}

  defp container?(type, payload, opts) do
    Registry.container?(type) or
      (Keyword.get(opts, :heuristic, false) and Registry.looks_like_boxes?(payload))
  end
end
