defmodule ISOMedia.PlugChunkErrorTest do
  @moduledoc """
  A chunk write can fail with errors other than `:closed` (an adapter `:timeout`,
  `:enotconn`, …). The streaming loop must halt on any of them, not crash with a
  CaseClauseError mid-body.
  """
  use ExUnit.Case, async: true

  alias ISOMedia.Box

  # Minimal Plug adapter whose chunk/2 always fails with a non-:closed error.
  defmodule ErrAdapter do
    def send_chunked(_payload, _status, _headers), do: {:ok, "", :sent}
    def chunk(_payload, _data), do: {:error, :timeout}
  end

  test "a non-:closed chunk error halts the stream instead of crashing" do
    tree = [%Box{type: "free", data: :binary.copy(<<1>>, 500), size_mode: :compact}]

    conn = %Plug.Conn{
      adapter: {ErrAdapter, :init},
      method: "GET",
      owner: self(),
      req_headers: []
    }

    opts = ISOMedia.Plug.init(resolver: fn _ -> {:ok, tree} end)

    assert %Plug.Conn{state: :chunked, halted: true} = ISOMedia.Plug.call(conn, opts)
  end
end
