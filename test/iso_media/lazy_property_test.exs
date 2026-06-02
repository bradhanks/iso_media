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

  # Same generator but with `moov` placed AFTER `mdat`, so `faststart/1` actually
  # relocates `moov` and rewrites every chunk offset (a real test of the offset path).
  defp movie_moov_last do
    gen all(
          chunks <- list_of(binary(min_length: 1, max_length: 16), min_length: 1, max_length: 5)
        ) do
      MP4Builder.build(chunks, moov_position: :last)
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

  property "lazy faststart + streaming write == eager faststart + serialize (moov relocated)" do
    check all(%{binary: bin} <- movie_moov_last()) do
      path = tmp()
      out = tmp()
      File.write!(path, bin)

      try do
        {:ok, eager} = ISOMedia.read(path)

        # The generated layout has moov LAST, so faststart is a real relocation,
        # not a no-op — guard against a vacuous pass.
        assert List.last(eager).type == "moov"
        eager_bytes = eager |> ISOMedia.faststart() |> ISOMedia.Serializer.serialize()
        refute eager_bytes == bin, "faststart should have moved moov and changed the bytes"

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
