defmodule ISOMedia.SampleTableTest do
  use ExUnit.Case
  alias ISOMedia.{SampleTable, Sample}

  defp leaf(type, data), do: <<8 + byte_size(data)::32, type::binary, data::binary>>
  defp container(type, inner), do: <<8 + byte_size(inner)::32, type::binary, inner::binary>>

  # 3 samples: sizes 10/20/30; chunk1 = samples 1&2 @offset 1000, chunk2 = sample 3 @offset 2000.
  defp sample_trak(extra \\ <<>>) do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 3::32, 100::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 2::32, 1::32, 2::32, 1::32, 2::32, 1::32, 1::32>>)
    stsz = leaf("stsz", <<0, 0, 0, 0, 0::32, 3::32, 10::32, 20::32, 30::32>>)
    stco = leaf("stco", <<0, 0, 0, 0, 2::32, 1000::32, 2000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stsz <> stco <> extra)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 7::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    trak_box
  end

  test "builds the sample index by cross-referencing the tables" do
    samples = SampleTable.build(sample_trak())

    assert [s1, s2, s3] = samples

    assert %Sample{index: 1, chunk_index: 1, dts: 0, pts: 0, size: 10, offset: 1000, sync?: true} =
             s1

    assert %Sample{
             index: 2,
             chunk_index: 1,
             dts: 100,
             pts: 100,
             size: 20,
             offset: 1010,
             sync?: true
           } = s2

    assert %Sample{
             index: 3,
             chunk_index: 2,
             dts: 200,
             pts: 200,
             size: 30,
             offset: 2000,
             sync?: true
           } = s3
  end

  test "stss marks only listed samples as sync" do
    stss = leaf("stss", <<0, 0, 0, 0, 1::32, 1::32>>)
    samples = SampleTable.build(sample_trak(stss))
    assert Enum.map(samples, & &1.sync?) == [true, false, false]
  end

  test "ctts shifts pts relative to dts" do
    ctts = leaf("ctts", <<0, 0, 0, 0, 1::32, 3::32, 5::32>>)
    samples = SampleTable.build(sample_trak(ctts))
    assert Enum.map(samples, & &1.pts) == [5, 105, 205]
  end

  test "raises on stz2 (unsupported)" do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf("stts", <<0, 0, 0, 0, 1::32, 1::32, 1::32>>)
    stsc = leaf("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stz2 = leaf("stz2", <<0, 0, 0, 0, 0::24, 8, 1::32, 10>>)
    stco = leaf("stco", <<0, 0, 0, 0, 1::32, 1000::32>>)
    stbl = container("stbl", stsd <> stts <> stsc <> stz2 <> stco)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    assert_raise ArgumentError, ~r/stz2/, fn -> SampleTable.build(trak_box) end
  end

  test "raises when a required table is missing" do
    stsd = leaf("stsd", <<0, 0, 0, 0, 0::32>>)
    stbl = container("stbl", stsd)
    tkhd = leaf("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    trak = container("trak", tkhd <> container("mdia", container("minf", stbl)))
    {:ok, [trak_box]} = ISOMedia.parse(trak)
    assert_raise ArgumentError, fn -> SampleTable.build(trak_box) end
  end
end
