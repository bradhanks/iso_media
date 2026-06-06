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

    test "the synthetic AAC-LC esds also yields sample_rate 44100 (freq index 4)" do
      dsi = <<0x05, 0x02, 0x12, 0x08>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      es = <<0x03, byte_size(<<0::16, 0::8>> <> dcd), 0::16, 0::8>> <> dcd
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_sample_rate(esds, 999) == 44100
    end

    test "HE-AAC esds yields mp4a.40.5" do
      # AudioSpecificConfig with audioObjectType 5 (top 5 bits of 0x28 = 00101)
      dsi = <<0x05, 0x02, 0x28, 0x00>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      es = <<0x03, byte_size(<<0::16, 0::8>> <> dcd), 0::16, 0::8>> <> dcd
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_codec(esds) == "mp4a.40.5"
    end

    test "walks an ES_Descriptor with streamDependenceFlag set (does not fall back)" do
      dsi = <<0x05, 0x02, 0x12, 0x08>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      # ES flags 0x80 (streamDependenceFlag) -> 2 extra bytes (dependsOn_ES_ID) after flags
      es_body = <<0::16, 0x80, 0xAB, 0xCD>> <> dcd
      es = <<0x03, byte_size(es_body)>> <> es_body
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_codec(esds) == "mp4a.40.2"
    end

    test "a 96 kHz esds (freq index 0) reports sample_rate 96000, not a truncated value" do
      # AudioSpecificConfig: aot 2 (00010), freq index 0 (0000) -> 0x10, 0x00
      dsi = <<0x05, 0x02, 0x10, 0x00>>
      dcd = <<0x04, 0x0D, 0x40, 0x15, 0::24, 0::32, 0::32>> <> dsi
      es = <<0x03, byte_size(<<0::16, 0::8>> <> dcd), 0::16, 0::8>> <> dcd
      esds = <<0::32>> <> es
      assert ISOMedia.Codec.mp4a_sample_rate(esds, 1) == 96000
    end

    test "falls back to the given rate when the esds can't be walked" do
      assert ISOMedia.Codec.mp4a_sample_rate(<<0::32, 0x03, 0x02, 0xFF>>, 48000) == 48000
      assert ISOMedia.Codec.mp4a_codec(<<0::32, 0x03, 0x02, 0xFF>>) == "mp4a.40.2"
    end
  end

  describe "track_info/2 — errors and invariants" do
    test "raises on an unsupported codec format" do
      # Minimal hand-built trak: info/1 needs tkhd (track_id), mdia/mdhd, mdia/minf/stbl/stsd.
      tkhd = %ISOMedia.Box{
        type: "tkhd",
        data: <<0::8, 0::24, 0::32, 0::32, 1::32, 0::32, 0::32, 0::480>>
      }

      mdhd = %ISOMedia.Box{
        type: "mdhd",
        data: <<0::8, 0::24, 0::32, 0::32, 1000::32, 0::32, 0x55C4::16, 0::16>>
      }

      stsd = %ISOMedia.Box{type: "stsd", data: <<0::8, 0::24, 1::32, 16::32, "hvc1", 0::64>>}
      stbl = %ISOMedia.Box{type: "stbl", children: [stsd]}
      minf = %ISOMedia.Box{type: "minf", children: [stbl]}
      mdia = %ISOMedia.Box{type: "mdia", children: [mdhd, minf]}
      trak = %ISOMedia.Box{type: "trak", children: [tkhd, mdia]}
      moov = %ISOMedia.Box{type: "moov", children: [trak]}

      assert_raise ArgumentError, ~r/unsupported codec hvc1/, fn ->
        ISOMedia.track_info([moov], 1)
      end
    end

    test "raises when the track_id is absent" do
      {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")

      assert_raise ArgumentError, ~r/no track with track_id 999/, fn ->
        ISOMedia.track_info(boxes, 999)
      end
    end

    test "track_info does not disturb the byte-for-byte round trip" do
      bin = File.read!("test/fixtures/sample_av.mp4")
      {:ok, boxes} = ISOMedia.parse(bin)
      _ = ISOMedia.track_info(boxes, hd(ISOMedia.track_ids(boxes)))
      assert ISOMedia.serialize(boxes) == bin
    end
  end
end
