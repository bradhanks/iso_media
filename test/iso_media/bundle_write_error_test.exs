defmodule ISOMedia.BundleWriteErrorTest do
  @moduledoc """
  `write_hls/3` and `write_dash/3` must surface a failed segment/manifest write as
  `{:error, reason}` (the contract `write_segments/3` already honors), not crash with a
  MatchError on `{:ok, _} = ...`.
  """
  use ExUnit.Case, async: true

  defp fragged do
    {:ok, b} = ISOMedia.read("test/fixtures/sample_keyint.mp4")
    ISOMedia.fragment(b, target_duration: 0.5)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "iso_bundle_err_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, boxes: fragged()}
  end

  test "write_hls returns {:error, _} when a segment path is unwritable", %{dir: dir, boxes: b} do
    # Pre-create a directory where init.mp4 must be written → write/2 fails with :eisdir.
    File.mkdir_p!(Path.join(dir, "init.mp4"))
    assert {:error, _reason} = ISOMedia.write_hls(dir, b)
  end

  test "write_dash returns {:error, _} when a segment path is unwritable", %{dir: dir, boxes: b} do
    File.mkdir_p!(Path.join(dir, "init.mp4"))
    assert {:error, _reason} = ISOMedia.write_dash(dir, b)
  end

  test "write_hls still returns {:ok, paths} on success", %{dir: dir, boxes: b} do
    assert {:ok, [master, media | _segs]} = ISOMedia.write_hls(dir, b)
    assert File.exists?(master)
    assert File.exists?(media)
  end
end
