defmodule ISOMedia.RecursiveIOTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FileSlice}

  test "write/2 refuses to overwrite a source file referenced inside a nested segment list" do
    src = Path.join(System.tmp_dir!(), "rio_src_#{System.unique_integer([:positive])}.bin")
    File.write!(src, <<0, 1, 2, 3>>)
    on_exit(fn -> File.rm(src) end)

    tree = [
      %Box{type: "ftyp", size_mode: :compact, data: <<0, 0, 0, 0>>},
      %Box{
        type: "mdat",
        size_mode: :compact,
        data: [<<9>>, [%FileSlice{path: src, offset: 0, length: 4}]]
      }
    ]

    assert_raise ArgumentError, ~r/same file as a FileSlice source|is also a FileSlice source/, fn ->
      ISOMedia.write(src, tree)
    end
  end

  @fixture Path.expand("../fixtures/sample_av.mp4", __DIR__)

  defp tmp(name),
    do: Path.join(System.tmp_dir!(), "rio_#{name}_#{System.unique_integer([:positive])}.mp4")

  test "chained trim |> concat |> trim matches a disk-round-trip pipeline byte-for-byte" do
    {:ok, a} = ISOMedia.read(@fixture)

    # Fully in-memory: nested segment trees, no intermediate disk writes.
    in_memory =
      a
      |> ISOMedia.trim(0.2, 0.8)
      |> then(fn t1 -> ISOMedia.concat([t1, t1]) end)
      |> ISOMedia.trim(0.1, 0.5)
      |> ISOMedia.serialize()

    # Same operations with a write + re-read between every stage.
    f1 = tmp("t1")
    f2 = tmp("c")

    on_exit(fn ->
      File.rm(f1)
      File.rm(f2)
    end)

    :ok = ISOMedia.write(f1, ISOMedia.trim(a, 0.2, 0.8))
    {:ok, t1d} = ISOMedia.read(f1)
    :ok = ISOMedia.write(f2, ISOMedia.concat([t1d, t1d]))
    {:ok, cd} = ISOMedia.read(f2)
    disk = ISOMedia.serialize(ISOMedia.trim(cd, 0.1, 0.5))

    assert in_memory == disk
  end

  test "every sample of the chained output resolves to the same bytes as the disk pipeline" do
    {:ok, a} = ISOMedia.read(@fixture)
    [track | _] = ISOMedia.track_ids(a)

    chained = a |> ISOMedia.trim(0.2, 0.8) |> then(&ISOMedia.concat([&1, &1]))

    f1 = tmp("t1b")
    on_exit(fn -> File.rm(f1) end)
    :ok = ISOMedia.write(f1, ISOMedia.trim(a, 0.2, 0.8))
    {:ok, t1d} = ISOMedia.read(f1)
    disk = ISOMedia.concat([t1d, t1d])

    # Serializing both must yield identical bytes (proves every resolved sample matches).
    assert ISOMedia.serialize(chained) == ISOMedia.serialize(disk)
    assert length(ISOMedia.samples(chained, track)) == length(ISOMedia.samples(disk, track))
  end

  test "lazy-parsed inputs chain to the same bytes as eager inputs" do
    {:ok, eager} = ISOMedia.read(@fixture)
    {:ok, lazy} = ISOMedia.read(@fixture, lazy: true)

    chain = fn boxes ->
      boxes |> ISOMedia.trim(0.2, 0.8) |> then(&ISOMedia.concat([&1, &1])) |> ISOMedia.serialize()
    end

    assert chain.(lazy) == chain.(eager)
  end
end
