defmodule ISOMedia.DASHTest do
  use ExUnit.Case, async: true

  defp fragged do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    ISOMedia.fragment(b, target_duration: 0.5)
  end

  test "manifest is the byte-exact static/VOD MPD" do
    expected = """
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" minBufferTime="PT1.5S" mediaPresentationDuration="PT2.000S">
      <Period>
        <AdaptationSet contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1">
          <Representation id="1" codecs="avc1.64000a,mp4a.40.2" bandwidth="96392" width="128" height="96">
            <SegmentTemplate timescale="10240" initialization="init.mp4" media="seg-$Number$.m4s" startNumber="1">
              <SegmentTimeline>
                <S d="10240"/>
                <S d="10240"/>
              </SegmentTimeline>
            </SegmentTemplate>
          </Representation>
        </AdaptationSet>
      </Period>
    </MPD>
    """

    assert ISOMedia.dash_manifest(fragged()) == expected
  end

  test "manifest is well-formed XML (independent of exact bytes)" do
    mpd = ISOMedia.dash_manifest(fragged())
    # :xmerl_scan raises on malformed XML; a clean parse proves structural validity.
    assert {_doc, []} = :xmerl_scan.string(String.to_charlist(mpd))
  end

  test "attr_escape escapes the five XML-significant characters (ampersand first)" do
    assert ISOMedia.DASH.attr_escape(~s(a & b < c > d " e)) ==
             ~s(a &amp; b &lt; c &gt; d &quot; e)
  end

  test "audio-only: audio/mp4, audio codec, no width/height, still valid XML" do
    {:ok, b} = ISOMedia.read("test/fixtures/sample.m4a")
    frag = ISOMedia.fragment(b, target_duration: 0.3)
    mpd = ISOMedia.dash_manifest(frag)

    assert mpd =~ ~s(contentType="audio")
    assert mpd =~ ~s(mimeType="audio/mp4")
    assert mpd =~ ~s(codecs="mp4a.40.2")
    # leading space avoids a false match inside `bandwidth="…"`
    refute mpd =~ ~s( width=")
    refute mpd =~ ~s( height=")
    assert {_doc, []} = :xmerl_scan.string(String.to_charlist(mpd))
  end

  test "raises on progressive (non-fragmented) input" do
    {:ok, prog} = ISOMedia.read("test/fixtures/sample_av.mp4")
    assert_raise ArgumentError, fn -> ISOMedia.dash_manifest(prog) end
  end

  describe "write_dash/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "iso_dash_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes manifest.mpd + init.mp4 + seg-N.m4s; all referenced files exist", %{dir: dir} do
      frag = fragged()
      n = Enum.count(frag, &(&1.type == "moof"))

      assert {:ok, paths} = ISOMedia.write_dash(dir, frag)

      assert paths == [
               Path.join(dir, "manifest.mpd"),
               Path.join(dir, "init.mp4")
               | Enum.map(1..n, &Path.join(dir, "seg-#{&1}.m4s"))
             ]

      assert Enum.all?(paths, &File.exists?/1)
      mpd = File.read!(Path.join(dir, "manifest.mpd"))
      assert mpd =~ ~s(initialization="init.mp4")
      assert mpd =~ ~s(media="seg-$Number$.m4s")
    end

    test "segment_template drives both the manifest and the written filenames", %{dir: dir} do
      frag = fragged()

      assert {:ok, _} =
               ISOMedia.write_dash(dir, frag,
                 segment_template: "chunk-$Number$.m4s",
                 manifest_name: "stream.mpd"
               )

      assert File.exists?(Path.join(dir, "stream.mpd"))
      assert File.exists?(Path.join(dir, "chunk-1.m4s"))
      assert File.read!(Path.join(dir, "stream.mpd")) =~ ~s(media="chunk-$Number$.m4s")
    end
  end
end
