defmodule ISOMedia.SerializerTest do
  use ExUnit.Case
  alias ISOMedia.{Parser, Serializer}

  defp round_trips!(bin) do
    {:ok, boxes} = Parser.parse(bin)
    assert Serializer.serialize(boxes) == bin
  end

  test "round-trips a compact leaf" do
    round_trips!(<<12::32, "free", 1, 2, 3, 4>>)
  end

  test "round-trips siblings" do
    round_trips!(<<8::32, "free", 9::32, "skip", 0>>)
  end

  test "round-trips a nested container" do
    inner = <<8::32, "mvhd", 8::32, "free">>
    round_trips!(<<8 + byte_size(inner)::32, "moov", inner::binary>>)
  end

  test "round-trips a 64-bit largesize box" do
    round_trips!(<<1::32, "mdat", 20::64, 9, 9, 9, 9>>)
  end

  test "round-trips a size-0 box" do
    round_trips!(<<0::32, "mdat", 7, 7, 7>>)
  end

  test "round-trips a uuid box" do
    round_trips!(<<27::32, "uuid", 0::128, 1, 2, 3>>)
  end

  test "serialize/1 accepts a single box" do
    {:ok, [box]} = Parser.parse(<<8::32, "free">>)
    assert Serializer.serialize(box) == <<8::32, "free">>
  end
end
