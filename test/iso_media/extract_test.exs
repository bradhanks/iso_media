defmodule ISOMedia.ExtractTest do
  use ExUnit.Case
  alias ISOMedia.Support.MP4Builder

  defp parsed(specs) do
    %{binary: bin} = MP4Builder.build_tracks(specs)
    path = Path.join(System.tmp_dir!(), "iso_ex_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)
    {bin, path}
  end

  @specs [
    %{id: 7, chunks: [[<<1, 1>>, <<2, 2, 2>>], [<<3>>]]},
    %{id: 8, chunks: [[<<4, 4, 4, 4>>, <<5>>]]}
  ]

  test "extract_track keeps one track and its samples resolve to the original bytes" do
    {bin, _path} = parsed(@specs)
    {:ok, boxes} = ISOMedia.parse(bin)

    out_boxes = ISOMedia.extract_track(boxes, 7)
    out = ISOMedia.serialize(out_boxes)
    {:ok, reparsed} = ISOMedia.parse(out)

    assert ISOMedia.track_ids(reparsed) == [7]

    extracted = ISOMedia.samples(reparsed, 7)

    assert Enum.map(extracted, &binary_part(out, &1.offset, &1.size)) == [
             <<1, 1>>,
             <<2, 2, 2>>,
             <<3>>
           ]
  end

  test "lazy extract streams to disk and matches an eager extract" do
    {_bin, path} = parsed(@specs)

    {:ok, eager} = ISOMedia.read(path)
    eager_out = eager |> ISOMedia.extract_track(7) |> ISOMedia.serialize()

    {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
    lazy_tree = ISOMedia.extract_track(lazy, 7)
    # the new mdat is a segment list of FileSlices (not materialized)
    assert is_list(ISOMedia.Box.find(lazy_tree, ~w(mdat)).data)

    out = Path.join(System.tmp_dir!(), "iso_ex_out_#{System.unique_integer([:positive])}.mp4")
    on_exit(fn -> File.rm(out) end)
    assert :ok = ISOMedia.write(out, lazy_tree)
    assert File.read!(out) == eager_out
  end

  test "raises for an unknown track id" do
    {bin, _path} = parsed(@specs)
    {:ok, boxes} = ISOMedia.parse(bin)
    assert_raise ArgumentError, fn -> ISOMedia.extract_track(boxes, 999) end
  end
end
