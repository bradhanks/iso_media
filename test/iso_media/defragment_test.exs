defmodule ISOMedia.DefragmentTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FragmentIndex, MdatSource}

  @frag "test/fixtures/sample_frag.mp4"

  # Concatenate every sample's resolved bytes, in index order.
  defp sample_bytes(boxes, samples) do
    recs = MdatSource.collect(boxes)

    samples
    |> Enum.map(fn s ->
      seg = MdatSource.segment(recs, s.offset, s.size)
      ISOMedia.Box.read_data(%Box{type: "free", data: List.wrap(seg)})
    end)
    |> IO.iodata_to_binary()
  end

  test "output is a progressive [ftyp, moov, mdat] with no moof/mvex" do
    {:ok, boxes} = ISOMedia.read(@frag)
    out = ISOMedia.defragment(boxes)
    assert Enum.map(out, & &1.type) == ["ftyp", "moov", "mdat"]
    moov = Enum.find(out, &(&1.type == "moov"))
    refute Enum.any?(moov.children, &(&1.type == "mvex"))
    refute Enum.any?(out, &(&1.type == "moof"))
    refute FragmentIndex.fragmented?(out)
  end

  test "defragment preserves every sample's metadata and bytes per track" do
    {:ok, boxes} = ISOMedia.read(@frag)
    out = ISOMedia.defragment(boxes)
    {:ok, reparsed} = ISOMedia.parse(ISOMedia.serialize(out))

    for tid <- ISOMedia.track_ids(boxes) do
      frag_samples = ISOMedia.samples(boxes, tid)
      prog_samples = ISOMedia.samples(reparsed, tid)

      assert Enum.map(prog_samples, & &1.dts) == Enum.map(frag_samples, & &1.dts)
      assert Enum.map(prog_samples, & &1.pts) == Enum.map(frag_samples, & &1.pts)
      assert Enum.map(prog_samples, & &1.size) == Enum.map(frag_samples, & &1.size)
      assert Enum.map(prog_samples, & &1.sync?) == Enum.map(frag_samples, & &1.sync?)

      assert sample_bytes(reparsed, prog_samples) == sample_bytes(boxes, frag_samples)
    end
  end

  test "lazy and eager defragment produce identical bytes" do
    {:ok, eager} = ISOMedia.read(@frag)
    {:ok, lazy} = ISOMedia.read(@frag, lazy: true)

    assert ISOMedia.serialize(ISOMedia.defragment(eager)) ==
             ISOMedia.serialize(ISOMedia.defragment(lazy))
  end
end
