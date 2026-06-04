defmodule ISOMedia.SegmentTest do
  use ExUnit.Case
  alias ISOMedia.Box

  @keyint "test/fixtures/sample_keyint.mp4"

  defp fragged do
    {:ok, b} = ISOMedia.read(@keyint)
    ISOMedia.fragment(b, target_duration: 0.3)
  end

  defp sample_bytes(boxes, samples) do
    recs = ISOMedia.MdatSource.collect(boxes)

    samples
    |> Enum.map(fn smp ->
      seg = ISOMedia.MdatSource.segment(recs, smp.offset, smp.size)
      ISOMedia.Box.read_data(%Box{type: "x", data: List.wrap(seg)})
    end)
    |> IO.iodata_to_binary()
  end

  describe "split_segments/1" do
    test "init is [ftyp, moov] and each segment is [styp, moof, mdat]" do
      frag = fragged()
      moof_count = Enum.count(frag, &(&1.type == "moof"))
      %{init: init, segments: segments} = ISOMedia.split_segments(frag)

      assert Enum.map(init, & &1.type) == ["ftyp", "moov"]
      assert length(segments) == moof_count
      assert moof_count >= 2

      for seg <- segments do
        assert Enum.map(seg, & &1.type) == ["styp", "moof", "mdat"]
      end
    end

    test "styp copies the ftyp brands" do
      frag = fragged()
      ftyp = Enum.find(frag, &(&1.type == "ftyp"))
      %{segments: [[styp | _] | _]} = ISOMedia.split_segments(frag)
      assert styp.type == "styp"
      assert styp.data == ftyp.data
    end

    test "split is losslessly reversible (init ++ segments minus styp == original)" do
      frag = fragged()
      %{init: init, segments: segments} = ISOMedia.split_segments(frag)
      reassembled = init ++ Enum.flat_map(segments, fn [_styp, moof, mdat] -> [moof, mdat] end)
      assert ISOMedia.serialize(reassembled) == ISOMedia.serialize(frag)
    end

    test "init ++ one segment is a self-contained fragmented file whose samples resolve" do
      frag = fragged()
      %{init: init, segments: [seg1 | _]} = ISOMedia.split_segments(frag)
      standalone = init ++ seg1

      assert ISOMedia.FragmentIndex.fragmented?(standalone)
      [tid | _] = ISOMedia.track_ids(standalone)
      seg_samples = ISOMedia.samples(standalone, tid)
      frag_samples = ISOMedia.samples(frag, tid) |> Enum.take(length(seg_samples))

      assert seg_samples != []
      assert Enum.map(seg_samples, & &1.size) == Enum.map(frag_samples, & &1.size)
      assert Enum.map(seg_samples, & &1.dts) == Enum.map(frag_samples, & &1.dts)
      assert sample_bytes(standalone, seg_samples) == sample_bytes(frag, frag_samples)
    end

    test "raises on progressive input, missing ftyp/moov, or an orphan moof" do
      {:ok, prog} = ISOMedia.read(@keyint)
      assert_raise ArgumentError, fn -> ISOMedia.split_segments(prog) end

      no_ftyp = [%Box{type: "moov"}, %Box{type: "moof"}, %Box{type: "mdat", data: <<>>}]
      assert_raise ArgumentError, fn -> ISOMedia.split_segments(no_ftyp) end

      orphan = [
        %Box{type: "ftyp", data: <<"isom", 0::32>>},
        %Box{type: "moov"},
        %Box{type: "moof"},
        %Box{type: "moof"}
      ]

      assert_raise ArgumentError, fn -> ISOMedia.split_segments(orphan) end
    end
  end
end
