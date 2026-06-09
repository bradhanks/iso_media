defmodule ISOMedia.HTTP.ExtraHeadersTest do
  @moduledoc """
  `resource/2` accepts `:cache_control` and `:extra_headers` (documented by
  `ISOMedia.Plug`); they must actually appear on served responses.
  """
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP}

  defp tree, do: [%Box{type: "free", data: :binary.copy(<<7>>, 1000), size_mode: :compact}]
  defp request(method, headers), do: HTTP.from_headers(headers, method)

  test "cache_control option emits a Cache-Control header on a 200" do
    res = HTTP.resource(tree(), cache_control: "max-age=31536000, immutable")
    resp = HTTP.serve(res, request("GET", %{}))
    assert {"cache-control", "max-age=31536000, immutable"} in resp.headers
  end

  test "extra_headers are emitted verbatim" do
    res = HTTP.resource(tree(), extra_headers: [{"x-foo", "bar"}, {"x-baz", "qux"}])
    resp = HTTP.serve(res, request("GET", %{}))
    assert {"x-foo", "bar"} in resp.headers
    assert {"x-baz", "qux"} in resp.headers
  end

  test "extra headers also appear on a 206 range response" do
    res = HTTP.resource(tree(), cache_control: "no-cache")
    resp = HTTP.serve(res, request("GET", %{"range" => "bytes=0-99"}))
    assert resp.status == 206
    assert {"cache-control", "no-cache"} in resp.headers
  end

  test "no options => no cache-control or custom headers (unchanged default)" do
    res = HTTP.resource(tree(), [])
    resp = HTTP.serve(res, request("GET", %{}))
    refute Enum.any?(resp.headers, fn {k, _} -> k == "cache-control" end)
  end
end
