defmodule ISOMedia.FragmentTest do
  use ExUnit.Case
  alias ISOMedia.{Fragment, Sample}

  defp s(dts, sync?),
    do: %Sample{
      index: 0,
      chunk_index: 1,
      dts: dts,
      duration: 10,
      pts: dts,
      size: 5,
      offset: 0,
      sync?: sync?
    }

  describe "boundaries/2" do
    test "sparse keyframes: a boundary at the first sync >= last + target" do
      # keyframes at dts 0, 30, 60, 90; others non-sync
      samples =
        for d <- 0..90//10 do
          s(d, rem(d, 30) == 0)
        end

      # target 25: boundaries at 0, 30, 60, 90 (each next keyframe past +25)
      assert Fragment.boundaries(samples, 25) == [0, 30, 60, 90]
      # target 35: skip the keyframe at 30 (0+35=35 > 30), take 60, then 90
      assert Fragment.boundaries(samples, 35) == [0, 60]
    end

    test "all-sync (audio): boundaries purely by duration" do
      samples = for d <- 0..90//10, do: s(d, true)
      assert Fragment.boundaries(samples, 30) == [0, 30, 60, 90]
    end
  end

  describe "windows/2" do
    test "partitions samples into [b_i, b_{i+1}) by dts" do
      samples = for d <- 0..90//10, do: s(d, true)
      # boundaries 0, 40, 80 -> windows [0..30], [40..70], [80..90]
      windows = Fragment.windows(samples, [0, 40, 80])

      assert Enum.map(windows, fn run -> Enum.map(run, & &1.dts) end) ==
               [[0, 10, 20, 30], [40, 50, 60, 70], [80, 90]]
    end

    test "a track with no samples in a window yields an empty run there" do
      samples = [s(0, true), s(50, true)]
      windows = Fragment.windows(samples, [0, 20, 40])
      assert Enum.map(windows, &length/1) == [1, 0, 1]
    end
  end
end
