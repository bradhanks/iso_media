defmodule ISOMedia.BoxTest do
  use ExUnit.Case
  alias ISOMedia.Box

  test "defaults: a fresh box is a compact container with no children" do
    box = %Box{type: "moov"}
    assert box.type == "moov"
    assert box.data == nil
    assert box.children == []
    assert box.uuid == nil
    assert box.size_mode == :compact
  end

  test "container?/1 and leaf?/1 distinguish by data" do
    container = %Box{type: "moov", data: nil, children: []}
    leaf = %Box{type: "free", data: <<0, 0>>}
    assert Box.container?(container)
    refute Box.leaf?(container)
    assert Box.leaf?(leaf)
    refute Box.container?(leaf)
  end
end
