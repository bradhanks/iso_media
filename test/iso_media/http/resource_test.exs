defmodule ISOMedia.HTTP.ResourceTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP, Serializer}
  alias ISOMedia.HTTP.{Request, Resource}

  defp tree, do: [%Box{type: "free", data: <<1, 2, 3, 4, 5>>, size_mode: :compact}]

  describe "resource/2" do
    test "computes content_length, etag, content_type" do
      r = HTTP.resource(tree())
      assert %Resource{} = r
      assert r.content_length == byte_size(Serializer.serialize(tree()))
      assert String.starts_with?(r.etag, "\"")
      assert r.content_type == "application/mp4"
    end

    test "honors :content_type and :last_modified opts" do
      lm = {{2024, 1, 1}, {0, 0, 0}}
      r = HTTP.resource(tree(), content_type: "video/mp4", last_modified: lm)
      assert r.content_type == "video/mp4"
      assert r.last_modified == lm
    end

    test ":codecs appends a codecs= param" do
      r = HTTP.resource(tree(), codecs: true)
      assert r.content_type =~ ~r/^application\/mp4; codecs="/
    end
  end

  describe "from_headers/2" do
    test "normalizes header keys (case-insensitive) and method" do
      req =
        HTTP.from_headers(
          [{"Range", "bytes=0-9"}, {"If-None-Match", "\"abc\""}],
          "GET"
        )

      assert %Request{method: :get, range: "bytes=0-9", if_none_match: "\"abc\""} = req
    end

    test "unknown method is :other; accepts a map too" do
      req = HTTP.from_headers(%{"if-match" => "*"}, :post)
      assert req.method == :other
      assert req.if_match == "*"
    end
  end
end
