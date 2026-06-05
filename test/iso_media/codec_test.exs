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

  describe "track_info/2 — video (avc1)" do
    defp video_tid(boxes) do
      Enum.find(ISOMedia.track_ids(boxes), fn tid ->
        trak = ISOMedia.Extract.find_trak(boxes, tid)

        ISOMedia.Boxes.Handler.decode(ISOMedia.BoxPath.dig(trak, ~w(mdia hdlr))).handler_type ==
          "vide"
      end)
    end

    test "extracts avc1 codec string, dimensions, and media metadata" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      info = ISOMedia.track_info(boxes, video_tid(boxes))

      assert info.type == :video
      assert info.format == "avc1"
      assert info.codec == "avc1.64000a"
      assert info.width == 128
      assert info.height == 96
      assert info.timescale == 10240
      assert info.language == "und"
      assert info.sample_rate == nil and info.channels == nil
    end

    test "derives the avc1 codec string from avcC profile/compat/level bytes" do
      # avcC payload: configurationVersion=1, profile=0x64, compat=0x00, level=0x1f, then more
      avcc = <<1, 0x64, 0x00, 0x1F, 0xFF, 0xE1>>
      assert ISOMedia.Codec.avc1_codec(avcc) == "avc1.64001f"
    end
  end

  describe "track_info/2 — audio (mp4a)" do
    defp audio_tid(boxes) do
      Enum.find(ISOMedia.track_ids(boxes), fn tid ->
        trak = ISOMedia.Extract.find_trak(boxes, tid)

        ISOMedia.Boxes.Handler.decode(ISOMedia.BoxPath.dig(trak, ~w(mdia hdlr))).handler_type ==
          "soun"
      end)
    end

    test "extracts mp4a codec string, sample rate, channels" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
      info = ISOMedia.track_info(boxes, audio_tid(boxes))

      assert info.type == :audio
      assert info.format == "mp4a"
      assert info.codec == "mp4a.40.2"
      assert info.sample_rate == 44100
      assert info.channels == 1
      assert info.timescale == 44100
      assert info.width == nil and info.height == nil
    end

    test "derives mp4a.40.2 from an AAC-LC esds descriptor chain" do
      # esds: FullBox(4) + ES_Descriptor(0x03) -> DecoderConfig(0x04, oti 0x40)
      #       -> DecoderSpecificInfo(0x05, AudioSpecificConfig 0x12 -> aot 2)
      dsi = <<0x05, 0x02, 0x12, 0x08>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      es = <<0x03, byte_size(<<0::16, 0::8>> <> dcd), 0::16, 0::8>> <> dcd
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_codec(esds) == "mp4a.40.2"
    end
  end
end
