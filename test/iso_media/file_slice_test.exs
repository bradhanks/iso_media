defmodule ISOMedia.FileSliceTest do
  use ExUnit.Case
  alias ISOMedia.FileSlice

  setup do
    path = Path.join(System.tmp_dir!(), "iso_fs_#{System.unique_integer([:positive])}.bin")
    File.write!(path, <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "read/1 returns the exact byte range", %{path: path} do
    slice = %FileSlice{path: path, offset: 3, length: 4}
    assert FileSlice.read(slice) == <<3, 4, 5, 6>>
  end

  test "stream/3 writes the range to an io device in chunks", %{path: path} do
    out = Path.join(System.tmp_dir!(), "iso_fs_out_#{System.unique_integer([:positive])}.bin")
    on_exit(fn -> File.rm(out) end)
    slice = %FileSlice{path: path, offset: 2, length: 6}

    File.open!(out, [:write, :binary, :raw], fn io ->
      assert FileSlice.stream(slice, io, 2) == :ok
    end)

    assert File.read!(out) == <<2, 3, 4, 5, 6, 7>>
  end

  test "read/1 raises with context on an out-of-range read", %{path: path} do
    slice = %FileSlice{path: path, offset: 8, length: 100}
    assert_raise RuntimeError, ~r/FileSlice/, fn -> FileSlice.read(slice) end
  end
end
