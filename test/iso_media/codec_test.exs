defmodule ISOMedia.CodecTest do
  use ExUnit.Case
  alias ISOMedia.Codec

  describe "decode_language/1" do
    test "decodes packed ISO-639-2/T codes" do
      assert Codec.decode_language(<<0x55C4::16>>) == "und"
      assert Codec.decode_language(<<0x15C7::16>>) == "eng"
    end

    test "defaults to und on zero/invalid codes" do
      assert Codec.decode_language(<<0::16>>) == "und"
      # a 5-bit value of 0 maps to a backtick — must fall back, not emit junk
      assert Codec.decode_language(<<0x0042::16>>) == "und"
    end
  end

  describe "decode_expandable_length/1" do
    test "single-byte length" do
      assert Codec.decode_expandable_length(<<0x25, 0xFF>>) == {37, <<0xFF>>}
    end

    test "multi-byte (continuation) length, e.g. the ffmpeg 0x80 0x80 0x80 LL form" do
      assert Codec.decode_expandable_length(<<0x80, 0x80, 0x80, 0x25>>) == {37, <<>>}
    end
  end

  describe "find_sub_box/2" do
    test "returns the payload of the first matching sub-box" do
      bin = <<10::32, "free", 0, 0, 12::32, "avcC", 9, 9, 9, 9>>
      assert Codec.find_sub_box(bin, "avcC") == <<9, 9, 9, 9>>
    end

    test "raises when the sub-box is absent" do
      assert_raise ArgumentError, fn -> Codec.find_sub_box(<<8::32, "free">>, "avcC") end
    end
  end
end
