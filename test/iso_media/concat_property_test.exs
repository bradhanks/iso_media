defmodule ISOMedia.ConcatPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  # Compatible clips: each has exactly 2 tracks; per clip the chunk shapes vary but
  # stsd (stub) and timescale are identical across all clips, so they concat losslessly.
  # Multiple chunks per track (a list of lists), so concat exercises run_lengths
  # concatenation across chunk boundaries, not just a single trivial chunk.
  defp clip_gen do
    gen all(
          t1 <-
            list_of(list_of(binary(min_length: 1, max_length: 5), min_length: 1, max_length: 3),
              min_length: 1,
              max_length: 3
            ),
          t2 <-
            list_of(list_of(binary(min_length: 1, max_length: 5), min_length: 1, max_length: 3),
              min_length: 1,
              max_length: 3
            )
        ) do
      t1_samples = List.flatten(t1)
      t2_samples = List.flatten(t2)

      specs = [
        %{id: 1, chunks: t1, durations: List.duplicate(10, length(t1_samples))},
        %{id: 2, chunks: t2, durations: List.duplicate(10, length(t2_samples))}
      ]

      %{t1: t1_samples, t2: t2_samples, binary: MP4Builder.build_tracks(specs).binary}
    end
  end

  property "concat of N clips appends every track's samples byte-identically" do
    check all(clips <- list_of(clip_gen(), min_length: 2, max_length: 4)) do
      parsed =
        Enum.map(clips, fn %{binary: bin} ->
          {:ok, b} = ISOMedia.parse(bin)
          b
        end)

      out = parsed |> ISOMedia.concat() |> ISOMedia.serialize()
      {:ok, reparsed} = ISOMedia.parse(out)

      assert ISOMedia.track_ids(reparsed) == [1, 2]

      expected1 = Enum.flat_map(clips, & &1.t1)
      expected2 = Enum.flat_map(clips, & &1.t2)

      got1 = ISOMedia.samples(reparsed, 1) |> Enum.map(&binary_part(out, &1.offset, &1.size))
      got2 = ISOMedia.samples(reparsed, 2) |> Enum.map(&binary_part(out, &1.offset, &1.size))

      assert got1 == expected1
      assert got2 == expected2
    end
  end
end
