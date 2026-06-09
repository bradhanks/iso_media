defmodule ISOMedia.HTTP.BodyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.{Box, HTTP, Serializer}

  defp az(b), do: 0x41 + rem(b, 26)
  defp printable(<<a, b, c, d>>), do: <<az(a), az(b), az(c), az(d)>>

  defp leaf_box do
    gen all(<<a, b, c, d>> <- binary(length: 4), data <- binary(min_length: 1, max_length: 60)) do
      %Box{type: printable(<<a, b, c, d>>), data: data, size_mode: :compact}
    end
  end

  defp tree_gen, do: list_of(leaf_box(), min_length: 1, max_length: 6)

  defp body_bin(resp), do: resp |> HTTP.body_iodata() |> IO.iodata_to_binary()
  defp stream_bin(resp), do: resp |> HTTP.body_stream(8) |> Enum.into("")
  defp request(method, headers), do: HTTP.from_headers(headers, method)

  defp clen(resp),
    do: resp.headers |> Enum.into(%{}) |> Map.fetch!("content-length") |> String.to_integer()

  describe "single-range + full bodies (invariants #1, #2, #4, #5)" do
    property "200 body == serialize; 206 body == binary_part; content-length exact; stream == iodata" do
      check all(boxes <- tree_gen(), seed <- integer(0..1_000_000)) do
        full = Serializer.serialize(boxes)
        total = byte_size(full)
        res = HTTP.resource(boxes)

        r200 = HTTP.serve(res, request("GET", %{}))
        assert body_bin(r200) == full
        assert clen(r200) == total

        off = rem(seed, total)
        len = rem(div(seed, 7), total - off) + 1
        r206 = HTTP.serve(res, request("GET", %{"range" => "bytes=#{off}-#{off + len - 1}"}))
        assert body_bin(r206) == :binary.part(full, off, len)
        assert clen(r206) == len
        assert stream_bin(r206) == body_bin(r206)
      end
    end
  end

  describe "multipart (invariants #3, #4, #5)" do
    test "two disjoint ranges => reassembles to exact slices; content-length exact; stream==iodata" do
      boxes = [%Box{type: "free", data: :binary.copy(<<9>>, 1000), size_mode: :compact}]
      full = Serializer.serialize(boxes)
      res = HTTP.resource(boxes)
      resp = HTTP.serve(res, request("GET", %{"range" => "bytes=0-99,500-599"}))

      assert resp.status == 206
      {:multipart, boundary, _parts, _idx} = resp.body

      ct = resp.headers |> Enum.into(%{}) |> Map.fetch!("content-type")
      assert ct == "multipart/byteranges; boundary=" <> boundary

      bin = body_bin(resp)
      assert clen(resp) == byte_size(bin)
      assert stream_bin(resp) == bin

      # Reassemble each part: parse its Content-Range and confirm the payload matches serialize.
      parts =
        bin
        |> :binary.split("--" <> boundary, [:global])
        |> Enum.flat_map(fn chunk ->
          case Regex.run(~r/Content-Range: bytes (\d+)-(\d+)\/\d+\r\n\r\n/, chunk, return: :index) do
            [{whole_s, whole_l}, {fs, fl}, {ls, ll}] ->
              f = chunk |> binary_part(fs, fl) |> String.to_integer()
              l = chunk |> binary_part(ls, ll) |> String.to_integer()
              body_start = whole_s + whole_l
              payload = binary_part(chunk, body_start, l - f + 1)
              [{f, l, payload}]

            _ ->
              []
          end
        end)

      assert length(parts) == 2

      for {f, l, payload} <- parts do
        assert payload == :binary.part(full, f, l - f + 1)
      end
    end
  end
end
