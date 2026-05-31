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
end
