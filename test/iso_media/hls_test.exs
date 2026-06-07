defmodule ISOMedia.HLSTest do
  use ExUnit.Case, async: true

  defp fragged do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    ISOMedia.fragment(b, target_duration: 0.5)
  end

  test "media_playlist is the byte-exact VOD playlist" do
    expected = """
    #EXTM3U
    #EXT-X-VERSION:7
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-TARGETDURATION:1
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:1.000,
    seg-1.m4s
    #EXTINF:1.000,
    seg-2.m4s
    #EXT-X-ENDLIST
    """

    assert ISOMedia.hls_media_playlist(fragged()) == expected
  end

  test "raises on progressive (non-fragmented) input" do
    {:ok, prog} = ISOMedia.read("test/fixtures/sample_av.mp4")
    assert_raise ArgumentError, fn -> ISOMedia.hls_media_playlist(prog) end
  end

  test "master_playlist is the byte-exact multivariant playlist" do
    expected = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=96392,CODECS="avc1.64000a,mp4a.40.2",RESOLUTION=128x96
    media.m3u8
    """

    assert ISOMedia.hls_master_playlist(fragged()) == expected
  end
end
