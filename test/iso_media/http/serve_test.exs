defmodule ISOMedia.HTTP.ServeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP}

  defp tree, do: [%Box{type: "free", data: :binary.copy(<<7>>, 1000), size_mode: :compact}]
  defp res(opts \\ []), do: HTTP.resource(tree(), opts)
  defp request(method, headers), do: HTTP.from_headers(headers, method)

  describe "serve/2 status + headers" do
    test "no Range => 200 full with content-length + accept-ranges" do
      resp = HTTP.serve(res(), request("GET", %{}))
      assert resp.status == 200
      assert {"accept-ranges", "bytes"} in resp.headers
      assert {"content-length", "1008"} in resp.headers
      assert match?({:full, _}, resp.body)
    end

    test "single range => 206 with content-range" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99"}))
      assert resp.status == 206
      assert {"content-range", "bytes 0-99/1008"} in resp.headers
      assert {"content-length", "100"} in resp.headers
      assert match?({:range, _, 0, 100}, resp.body)
    end

    test "unsatisfiable => 416 with content-range bytes */total" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=99999-"}))
      assert resp.status == 416
      assert {"content-range", "bytes */1008"} in resp.headers
      assert resp.body == :empty
    end

    test "non-GET/HEAD => 405 with Allow" do
      resp = HTTP.serve(res(), request("POST", %{}))
      assert resp.status == 405
      assert {"allow", "GET, HEAD"} in resp.headers
    end

    test "HEAD parity: same status+headers as GET, empty body (invariant #10)" do
      get = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99"}))
      head = HTTP.serve(res(), request("HEAD", %{"range" => "bytes=0-99"}))
      assert head.status == get.status
      assert head.headers == get.headers
      assert head.body == :empty
    end

    test "If-None-Match match => 304 empty" do
      r = res()
      resp = HTTP.serve(r, request("GET", %{"if-none-match" => r.etag}))
      assert resp.status == 304
      assert resp.body == :empty
    end

    test "If-Range mismatch ignores Range => 200 full" do
      resp =
        HTTP.serve(res(), request("GET", %{"range" => "bytes=0-99", "if-range" => "\"stale\""}))

      assert resp.status == 200
      assert match?({:full, _}, resp.body)
    end

    test "last-modified header present on 200 and 304 when set" do
      lm = {{2024, 1, 1}, {0, 0, 0}}
      r = res(last_modified: lm)
      get200 = HTTP.serve(r, request("GET", %{}))
      assert Enum.any?(get200.headers, fn {k, _} -> k == "last-modified" end)

      not_mod = HTTP.serve(r, request("GET", %{"if-none-match" => r.etag}))
      assert not_mod.status == 304
      assert Enum.any?(not_mod.headers, fn {k, _} -> k == "last-modified" end)
    end

    test "If-Match miss => 412 with validator headers only (no accept-ranges)" do
      resp = HTTP.serve(res(), request("GET", %{"if-match" => "\"nope\""}))
      assert resp.status == 412
      assert resp.body == :empty
      assert {"etag", res().etag} in resp.headers
      refute Enum.any?(resp.headers, fn {k, _} -> k == "accept-ranges" end)
    end

    test "multi-range currently hits the temporary stub (200 full) until multipart lands" do
      resp = HTTP.serve(res(), request("GET", %{"range" => "bytes=0-9,20-29"}))
      assert resp.status == 200
      assert match?({:full, _}, resp.body)
    end
  end
end
