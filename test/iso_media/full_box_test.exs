defmodule ISOMedia.FullBoxTest do
  use ExUnit.Case
  alias ISOMedia.FullBox

  test "parse/1 splits version, flags, and remaining payload" do
    assert {1, <<0, 0, 3>>, <<10, 20>>} = FullBox.parse(<<1, 0, 0, 3, 10, 20>>)
  end

  test "encode/3 rebuilds the prefix and round-trips with parse/1" do
    bin = IO.iodata_to_binary(FullBox.encode(1, <<0, 0, 3>>, <<10, 20>>))
    assert bin == <<1, 0, 0, 3, 10, 20>>
    assert {1, <<0, 0, 3>>, <<10, 20>>} = FullBox.parse(bin)
  end
end
