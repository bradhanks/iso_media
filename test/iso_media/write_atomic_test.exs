defmodule ISOMedia.WriteAtomicTest do
  @moduledoc """
  `write/2` must be atomic: it writes through a temp file and renames into place, so a
  mid-stream failure (e.g. a `FileSlice` source that vanished) leaves the destination
  untouched rather than truncated/partial, and never leaves temp litter behind.
  """
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, FileSlice}

  setup do
    dir = Path.join(System.tmp_dir!(), "iso_write_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "a mid-stream failure leaves the existing destination untouched", %{dir: dir} do
    src = Path.join(dir, "src.bin")
    File.write!(src, :binary.copy(<<1>>, 2000))

    dest = Path.join(dir, "out.mp4")
    File.write!(dest, "ORIGINAL-CONTENT")

    # A leaf whose payload streams from `src` — then remove `src` so the stream raises.
    tree = [%Box{type: "mdat", data: %FileSlice{path: src, offset: 0, length: 2000}}]
    File.rm!(src)

    assert catch_error(ISOMedia.write(dest, tree))

    # Destination is byte-for-byte the original, and no temp file was left behind.
    assert File.read!(dest) == "ORIGINAL-CONTENT"
    assert Enum.filter(File.ls!(dir), &String.contains?(&1, "out.mp4.")) == []
  end

  test "a normal write still round-trips", %{dir: dir} do
    dest = Path.join(dir, "ok.mp4")
    tree = [Box.leaf("free", :binary.copy(<<7>>, 50))]

    assert ISOMedia.write(dest, tree) == :ok
    assert {:ok, parsed} = ISOMedia.read(dest)
    assert ISOMedia.serialize(parsed) == ISOMedia.serialize(tree)
  end
end
