defmodule ISOMedia.TrimPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # A track: 1..3 chunks of 1..3 samples (1..6 bytes), uniform duration 10, all sync.
  defp track_gen(id) do
    gen all(
          chunks <-
            list_of(list_of(binary(min_length: 1, max_length: 6), min_length: 1, max_length: 3),
              min_length: 1,
              max_length: 3
            )
        ) do
      n = chunks |> List.flatten() |> length()
      %{id: id, chunks: chunks, durations: List.duplicate(10, n)}
    end
  end

  defp movie do
    gen all(t1 <- track_gen(1), t2 <- track_gen(2)) do
      specs = [t1, t2]
      %{specs: specs, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  property "trimming [0, big) keeps all samples byte-identical and re-parses to the same tracks" do
    check all(%{binary: bin} <- movie()) do
      {:ok, boxes} = ISOMedia.parse(bin)
      {:ok, orig} = ISOMedia.parse(bin)

      out = boxes |> ISOMedia.trim(0, 1_000_000) |> ISOMedia.serialize()
      {:ok, reparsed} = ISOMedia.parse(out)

      assert ISOMedia.track_ids(reparsed) == ISOMedia.track_ids(orig)

      for id <- ISOMedia.track_ids(reparsed) do
        orig_bytes = ISOMedia.samples(orig, id) |> Enum.map(&binary_part(bin, &1.offset, &1.size))

        new_bytes =
          ISOMedia.samples(reparsed, id) |> Enum.map(&binary_part(out, &1.offset, &1.size))

        assert new_bytes == orig_bytes
      end
    end
  end

  property "lazy trim-write == eager trim-serialize" do
    check all(%{binary: bin} <- movie()) do
      path = Path.join(System.tmp_dir!(), "iso_tp_#{System.unique_integer([:positive])}.mp4")
      out = Path.join(System.tmp_dir!(), "iso_tpo_#{System.unique_integer([:positive])}.mp4")
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        eager_out = eager |> ISOMedia.trim(0, 1_000_000) |> ISOMedia.serialize()
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        :ok = ISOMedia.write(out, ISOMedia.trim(lazy, 0, 1_000_000))
        assert File.read!(out) == eager_out
      after
        File.rm(path)
        File.rm(out)
      end
    end
  end
end
