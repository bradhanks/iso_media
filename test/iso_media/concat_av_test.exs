defmodule ISOMedia.ConcatAvTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample_av.mp4"])

  test "concat a real file with itself doubles every track, byte-identical, continuous" do
    original = File.read!(@fixture)
    {:ok, a} = ISOMedia.parse(original)
    {:ok, b} = ISOMedia.parse(original)

    out = [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == ISOMedia.track_ids(a)

    for id <- ISOMedia.track_ids(reparsed) do
      orig_samples = ISOMedia.samples(a, id)
      out_samples = ISOMedia.samples(reparsed, id)

      # doubled count
      assert length(out_samples) == 2 * length(orig_samples)

      # bytes: out = (orig samples) ++ (orig samples)
      expected = Enum.map(orig_samples, &binary_part(original, &1.offset, &1.size))
      got = Enum.map(out_samples, &binary_part(out, &1.offset, &1.size))
      assert got == expected ++ expected

      # continuous timeline: dts strictly non-decreasing across the splice
      dts = Enum.map(out_samples, & &1.dts)
      assert dts == Enum.sort(dts)
    end
  end

  test "lazy concat streams and matches eager" do
    eager_out =
      with {:ok, a} <- ISOMedia.parse(File.read!(@fixture)),
           {:ok, b} <- ISOMedia.parse(File.read!(@fixture)),
           do: [a, b] |> ISOMedia.concat() |> ISOMedia.serialize()

    {:ok, la} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    {:ok, lb} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    out = Path.join(System.tmp_dir!(), "iso_concat_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)

    assert :ok = ISOMedia.write(out, ISOMedia.concat([la, lb]))
    assert File.read!(out) == eager_out
  end
end
