defmodule ISOMedia.ExtractPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # A chunk is 1..3 samples of 1..6 bytes each (distinct marker bytes).
  defp chunk_gen, do: list_of(binary(min_length: 1, max_length: 6), min_length: 1, max_length: 3)

  # A movie is 2..3 tracks, each 1..3 chunks; track ids assigned 1..n.
  defp movie do
    gen all(
          tracks <-
            list_of(list_of(chunk_gen(), min_length: 1, max_length: 3),
              min_length: 2,
              max_length: 3
            )
        ) do
      specs =
        tracks |> Enum.with_index(1) |> Enum.map(fn {chunks, id} -> %{id: id, chunks: chunks} end)

      %{specs: specs, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_exp_#{System.unique_integer([:positive])}.mp4")

  property "extracting any track yields one track whose samples are byte-identical to the originals" do
    check all(%{specs: specs, binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)

      for %{id: id, chunks: chunks} <- specs do
        expected = chunks |> List.flatten()
        out = boxes |> ISOMedia.extract_track(id) |> ISOMedia.serialize()
        {:ok, reparsed} = ISOMedia.parse(out)

        assert ISOMedia.track_ids(reparsed) == [id]
        got = ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))
        assert got == expected
      end
    end
  end

  property "lazy extract-write == eager extract-serialize" do
    check all(%{specs: specs, binary: bin} <- movie()) do
      path = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)

        for %{id: id} <- specs do
          eager_out = eager |> ISOMedia.extract_track(id) |> ISOMedia.serialize()
          out = tmp()

          try do
            :ok = ISOMedia.write(out, ISOMedia.extract_track(lazy, id))
            assert File.read!(out) == eager_out
          after
            File.rm(out)
          end
        end
      after
        File.rm(path)
      end
    end
  end
end
