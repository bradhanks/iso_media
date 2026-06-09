defmodule ISOMedia.HTTP.FacadeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.Box

  defp tree, do: [%Box{type: "free", data: <<1, 2, 3>>, size_mode: :compact}]

  test "ISOMedia re-exports the HTTP surface" do
    res = ISOMedia.http_resource(tree())
    req = ISOMedia.http_from_headers(%{"range" => "bytes=0-1"}, "GET")
    resp = ISOMedia.http_serve(res, req)
    assert resp.status == 206

    # body is the first 2 bytes of the serialized tree — compute the oracle, don't hardcode.
    expected = :binary.part(ISOMedia.serialize(tree()), 0, 2)
    assert IO.iodata_to_binary(ISOMedia.http_body_iodata(resp)) == expected

    assert ISOMedia.content_type(tree()) == "application/mp4"
    assert String.starts_with?(ISOMedia.etag(tree()), "\"")
  end

  test "http_body_stream re-export streams the same bytes as http_body_iodata" do
    res = ISOMedia.http_resource(tree())
    resp = ISOMedia.http_serve(res, ISOMedia.http_from_headers(%{}, "GET"))
    streamed = resp |> ISOMedia.http_body_stream(4) |> Enum.into("")
    assert streamed == IO.iodata_to_binary(ISOMedia.http_body_iodata(resp))
  end
end
