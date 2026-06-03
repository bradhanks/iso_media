defmodule ISOMedia.ConcatTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  # Two compatible clips: same track count, identical stsd stub, same (mdhd) timescale.
  # clip A track 1 = samples <<1>>,<<2>>; track 2 = <<5>>. clip B track 1 = <<3>>,<<4>>; track 2 = <<6>>.
  defp clip(t1_samples, t2_samples) do
    specs = [
      %{id: 1, chunks: [t1_samples], durations: List.duplicate(10, length(t1_samples))},
      %{id: 2, chunks: [t2_samples], durations: List.duplicate(10, length(t2_samples))}
    ]

    %{binary: bin} = MP4Builder.build_tracks(specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    boxes
  end

  test "concat appends every track's samples in order, byte-identical" do
    a = clip([<<1>>, <<2>>], [<<5>>])
    b = clip([<<3>>, <<4>>], [<<6>>])

    out = [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [1, 2]

    s1 = ISOMedia.samples(reparsed, 1)
    assert Enum.map(s1, &binary_part(out, &1.offset, &1.size)) == [<<1>>, <<2>>, <<3>>, <<4>>]
    # timeline is continuous: dts 0,10,20,30
    assert Enum.map(s1, & &1.dts) == [0, 10, 20, 30]

    s2 = ISOMedia.samples(reparsed, 2)
    assert Enum.map(s2, &binary_part(out, &1.offset, &1.size)) == [<<5>>, <<6>>]
  end

  test "concat of a single clip returns it unchanged" do
    a = clip([<<1>>], [<<5>>])
    assert ISOMedia.concat([a]) == a
  end

  test "raises on an empty list" do
    assert_raise ArgumentError, fn -> ISOMedia.concat([]) end
  end

  test "raises when track counts differ" do
    a = clip([<<1>>], [<<5>>])

    {:ok, b} =
      ISOMedia.parse(
        MP4Builder.build_tracks([%{id: 1, chunks: [[<<3>>]], durations: [10]}]).binary
      )

    assert_raise ArgumentError, ~r/track count/, fn -> ISOMedia.concat([a, b]) end
  end

  test "raises when stsd differs between inputs" do
    a = clip([<<1>>], [<<5>>])
    b = clip([<<3>>], [<<6>>])
    # mutate b's track-1 stsd so it no longer matches a's
    bad_b =
      ISOMedia.Box.update(b, ~w(moov trak mdia minf stbl stsd), fn stsd ->
        %{stsd | data: <<0, 0, 0, 0, 1::32>>}
      end)

    assert_raise ArgumentError, ~r/stsd/, fn -> ISOMedia.concat([a, bad_b]) end
  end

  # A single-track clip with TWO chunks (1 sample each) laid out physically out of
  # logical order: sample 2's bytes precede sample 1's in the mdat, so the stco
  # offsets are non-monotonic (chunk 1 offset > chunk 2 offset). This is the only way
  # to exercise the physical-vs-logical stco/stsc alignment — MP4Builder always emits
  # physically-monotonic per-track chunks.
  defp nonmono_clip(s1, s2) do
    leaf = fn type, data -> <<8 + byte_size(data)::32, type::binary, data::binary>> end
    container = fn type, inner -> <<8 + byte_size(inner)::32, type::binary, inner::binary>> end

    stsd = leaf.("stsd", <<0, 0, 0, 0, 0::32>>)
    stts = leaf.("stts", <<0, 0, 0, 0, 1::32, 2::32, 10::32>>)
    # one entry: every chunk holds 1 sample
    stsc = leaf.("stsc", <<0, 0, 0, 0, 1::32, 1::32, 1::32, 1::32>>)
    stsz = leaf.("stsz", <<0, 0, 0, 0, 0::32, 2::32, byte_size(s1)::32, byte_size(s2)::32>>)
    mdhd = leaf.("mdhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::16, 0::16>>)
    tkhd = leaf.("tkhd", <<0, 0, 0, 0, 0::32, 0::32, 1::32, 0::32, 0::32>>)
    ftyp = leaf.("ftyp", <<"isom", 0::32, "isom">>)

    moov_with = fn off1, off2 ->
      stco = leaf.("stco", <<0, 0, 0, 0, 2::32, off1::32, off2::32>>)
      stbl = container.("stbl", stsd <> stts <> stsc <> stsz <> stco)

      container.(
        "moov",
        container.("trak", tkhd <> container.("mdia", mdhd <> container.("minf", stbl)))
      )
    end

    payload_start = byte_size(ftyp) + byte_size(moov_with.(0, 0)) + 8
    # mdat physical layout: s2 first, then s1 → chunk1 (sample1=s1) offset is the larger.
    off2 = payload_start
    off1 = payload_start + byte_size(s2)
    bin = ftyp <> moov_with.(off1, off2) <> leaf.("mdat", s2 <> s1)
    {:ok, boxes} = ISOMedia.parse(bin)
    boxes
  end

  test "concat keeps logical sample order when source chunks are physically out of order" do
    a = nonmono_clip(<<1>>, <<2>>)
    b = nonmono_clip(<<3>>, <<4>>)

    out = [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    s = ISOMedia.samples(reparsed, 1)
    # logical decode order across both clips, NOT physical/byte order
    assert Enum.map(s, &binary_part(out, &1.offset, &1.size)) == [<<1>>, <<2>>, <<3>>, <<4>>]
  end
end
