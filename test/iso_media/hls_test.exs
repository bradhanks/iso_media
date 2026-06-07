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

  describe "write_hls/3 and edge cases" do
    setup do
      dir = Path.join(System.tmp_dir!(), "iso_hls_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes master + media + init + segments; all referenced files exist", %{dir: dir} do
      frag = fragged()
      n = Enum.count(frag, &(&1.type == "moof"))

      assert {:ok, paths} = ISOMedia.write_hls(dir, frag)

      assert paths == [
               Path.join(dir, "master.m3u8"),
               Path.join(dir, "media.m3u8"),
               Path.join(dir, "init.mp4")
               | Enum.map(1..n, &Path.join(dir, "seg-#{&1}.m4s"))
             ]

      assert Enum.all?(paths, &File.exists?/1)
      assert File.read!(Path.join(dir, "master.m3u8")) =~ "media.m3u8"
      media = File.read!(Path.join(dir, "media.m3u8"))
      assert media =~ ~s(URI="init.mp4")
      assert media =~ "seg-1.m4s"
    end

    test "audio-only: master has the audio codec and no RESOLUTION" do
      {:ok, b} = ISOMedia.read("test/fixtures/sample.m4a")
      frag = ISOMedia.fragment(b, target_duration: 0.3)
      master = ISOMedia.hls_master_playlist(frag)

      assert master =~ ~s(CODECS="mp4a.40.2")
      refute master =~ "RESOLUTION="
      assert ISOMedia.hls_media_playlist(frag) =~ "#EXT-X-ENDLIST"
    end

    test "custom opts flow through to playlists and filenames", %{dir: dir} do
      frag = fragged()

      assert {:ok, _} =
               ISOMedia.write_hls(dir, frag,
                 media_uri: "v.m3u8",
                 segment_pattern: fn i -> "c#{i}.m4s" end
               )

      assert File.exists?(Path.join(dir, "v.m3u8"))
      assert File.exists?(Path.join(dir, "c1.m4s"))
      assert File.read!(Path.join(dir, "master.m3u8")) =~ "v.m3u8"
      assert File.read!(Path.join(dir, "v.m3u8")) =~ "c1.m4s"
    end
  end
end
