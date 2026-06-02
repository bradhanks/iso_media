defmodule ISOMedia.LazyRoundtripTest do
  use ExUnit.Case

  @fixture Path.join([__DIR__, "..", "fixtures", "sample.mp4"])

  defp tmp(name),
    do: Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}.mp4")

  test "lazy parse + serialize == eager parse + serialize == original bytes" do
    original = File.read!(@fixture)
    {:ok, eager} = ISOMedia.read(@fixture)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)

    assert ISOMedia.Serializer.serialize(eager) == original
    assert ISOMedia.Serializer.serialize(lazy) == original
  end

  test "streaming write of a lazy tree reproduces the file" do
    out = tmp("lazy_write")
    on_exit(fn -> File.rm(out) end)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    assert :ok = ISOMedia.write(out, lazy)
    assert File.read!(out) == File.read!(@fixture)
  end

  test "faststart a lazy tree without materializing mdat, then stream it out" do
    out = tmp("lazy_faststart")
    on_exit(fn -> File.rm(out) end)

    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true, lazy_threshold: 64)
    fixed = ISOMedia.faststart(lazy)

    # mdat is still a FileSlice (never read into memory)
    assert %ISOMedia.FileSlice{} = ISOMedia.Box.find(fixed, ~w(mdat)).data

    assert :ok = ISOMedia.write(out, fixed)

    # The written file is valid: moov precedes mdat and chunks resolve.
    {:ok, reparsed} = ISOMedia.read(out)
    types = Enum.map(reparsed, & &1.type)
    assert Enum.find_index(types, &(&1 == "moov")) < Enum.find_index(types, &(&1 == "mdat"))

    original = File.read!(@fixture)
    out_bin = File.read!(out)

    old_offsets =
      with(
        {:ok, e} <- ISOMedia.read(@fixture),
        do: e
      )
      |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
      |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)

    new_offsets =
      reparsed
      |> ISOMedia.Box.find_all(~w(moov trak mdia minf stbl stco))
      |> Enum.flat_map(&ISOMedia.Boxes.ChunkOffset.decode(&1).offsets)

    assert length(old_offsets) == length(new_offsets)

    Enum.zip(old_offsets, new_offsets)
    |> Enum.each(fn {old, new} ->
      k = min(16, byte_size(original) - old)
      assert binary_part(out_bin, new, k) == binary_part(original, old, k)
    end)
  end
end
