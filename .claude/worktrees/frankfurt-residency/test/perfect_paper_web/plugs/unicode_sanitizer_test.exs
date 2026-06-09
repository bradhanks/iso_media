defmodule PerfectPaperWeb.Plugs.UnicodeSanitizerTest do
  use PerfectPaperWeb.ConnCase, async: true

  alias PerfectPaperWeb.Plugs.UnicodeSanitizer

  # U+200B zero-width space, U+E0052 Unicode tag 'R'
  @zw_space "\u200B"
  @tag_r "\u{E0052}"

  defp conn_with(body, query \\ %{}) do
    build_conn()
    |> Map.merge(%{body_params: body, query_params: query, path_params: %{}})
  end

  describe "strip mode (default)" do
    test "removes hidden Unicode from body params and rebuilds :params" do
      conn =
        conn_with(%{"text" => "Reply" <> @zw_space <> " VIOLET", "n" => 3})
        |> UnicodeSanitizer.call(UnicodeSanitizer.init([]))

      refute conn.halted
      assert conn.body_params["text"] == "Reply VIOLET"
      assert conn.params["text"] == "Reply VIOLET"
      assert conn.params["n"] == 3
    end

    test "sanitizes query params too" do
      conn =
        conn_with(%{}, %{"q" => "search" <> @tag_r})
        |> UnicodeSanitizer.call(UnicodeSanitizer.init([]))

      refute conn.halted
      assert conn.query_params["q"] == "search"
    end

    test "leaves clean params untouched and does not halt" do
      conn =
        conn_with(%{"text" => "perfectly normal"})
        |> UnicodeSanitizer.call(UnicodeSanitizer.init([]))

      refute conn.halted
      assert conn.body_params["text"] == "perfectly normal"
    end

    test "tolerates unfetched params" do
      conn =
        build_conn()
        |> UnicodeSanitizer.call(UnicodeSanitizer.init([]))

      refute conn.halted
    end
  end

  describe "block mode" do
    test "halts with 422 when hidden Unicode is present" do
      conn =
        conn_with(%{"text" => "x" <> @zw_space})
        |> UnicodeSanitizer.call(UnicodeSanitizer.init(mode: :block))

      assert conn.halted
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid input"}
    end

    test "passes clean requests through" do
      conn =
        conn_with(%{"text" => "clean"})
        |> UnicodeSanitizer.call(UnicodeSanitizer.init(mode: :block))

      refute conn.halted
    end
  end
end
