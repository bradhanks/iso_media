defmodule ISOMedia.RegistryTest do
  use ExUnit.Case
  alias ISOMedia.Registry

  test "known container types are recognized" do
    assert Registry.container?("moov")
    assert Registry.container?("trak")
    assert Registry.container?("stbl")
  end

  test "leaf / unknown types are not containers" do
    refute Registry.container?("mvhd")
    refute Registry.container?("free")
    refute Registry.container?("XXXX")
  end

  test "looks_like_boxes?/1 detects a sequence of valid child boxes" do
    payload = <<8::32, "free", 9::32, "skip", 0>>
    assert ISOMedia.Registry.looks_like_boxes?(payload)
  end

  test "looks_like_boxes?/1 rejects arbitrary leaf bytes" do
    refute ISOMedia.Registry.looks_like_boxes?(<<0, 1, 2, 3, 4, 5, 6, 7, 8>>)
    refute ISOMedia.Registry.looks_like_boxes?(<<1, 2>>)
  end
end
