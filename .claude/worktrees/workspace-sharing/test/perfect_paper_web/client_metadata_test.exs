defmodule PerfectPaperWeb.ClientMetadataTest do
  use ExUnit.Case, async: true

  alias PerfectPaperWeb.ClientMetadata

  test "prefers the first hop of x-forwarded-for" do
    info = %{x_headers: [{"x-forwarded-for", "203.0.113.7, 70.41.3.18"}]}
    assert ClientMetadata.ip_from_connect_info(info) == "203.0.113.7"
  end

  test "falls back to peer_data address when no forwarded header" do
    info = %{peer_data: %{address: {127, 0, 0, 1}}}
    assert ClientMetadata.ip_from_connect_info(info) == "127.0.0.1"
  end

  test "returns nil when no metadata is present" do
    assert ClientMetadata.ip_from_connect_info(%{}) == nil
  end
end
