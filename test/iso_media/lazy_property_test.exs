defmodule ISOMedia.LazyPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.Support.MP4Builder

  defp movie do
    gen all(
          chunks <- list_of(binary(min_length: 1, max_length: 16), min_length: 1, max_length: 5)
        ) do
      MP4Builder.build(chunks)
    end
  end

  defp tmp, do: Path.join(System.tmp_dir!(), "iso_lp_#{System.unique_integer([:positive])}.mp4")

  property "lazy and eager parses serialize to the same original bytes" do
    check all(%{binary: bin} <- movie()) do
      path = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        assert ISOMedia.Serializer.serialize(eager) == bin
        assert ISOMedia.Serializer.serialize(lazy) == bin
      after
        File.rm(path)
      end
    end
  end

  property "lazy faststart + streaming write == eager faststart + serialize" do
    check all(%{binary: bin} <- movie()) do
      path = tmp()
      out = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)
        eager_bytes = eager |> ISOMedia.faststart() |> ISOMedia.Serializer.serialize()

        {:ok, lazy} = ISOMedia.read(path, lazy: true, lazy_threshold: 1)
        :ok = ISOMedia.write(out, ISOMedia.faststart(lazy))

        assert File.read!(out) == eager_bytes
      after
        File.rm(path)
        File.rm(out)
      end
    end
  end
end
