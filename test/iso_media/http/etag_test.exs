defmodule ISOMedia.HTTP.ETagTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.{Box, FileSlice, HTTP}

  defp tree(data), do: [%Box{type: "free", data: data, size_mode: :compact}]

  describe "etag/2 :pure (invariant #7)" do
    test "same tree yields the same strong tag" do
      e1 = HTTP.etag(tree(<<1, 2, 3>>))
      e2 = HTTP.etag(tree(<<1, 2, 3>>))
      assert e1 == e2
      assert String.starts_with?(e1, "\"")
    end

    test "different content yields a different tag" do
      refute HTTP.etag(tree(<<1, 2, 3>>)) == HTTP.etag(tree(<<1, 2, 4>>))
    end

    test "distinct slice provider sequences never collide (framing is injective)" do
      a = [
        %Box{
          type: "mdat",
          data: %FileSlice{path: "ab", offset: 0, length: 4},
          size_mode: :compact
        }
      ]

      b = [
        %Box{
          type: "mdat",
          data: %FileSlice{path: "a", offset: 0, length: 4},
          size_mode: :compact
        },
        %Box{type: "mdat", data: %FileSlice{path: "b", offset: 4, length: 4}, size_mode: :compact}
      ]

      refute HTTP.etag(a) == HTTP.etag(b)
    end
  end

  describe "etag/2 :stat" do
    @tag :tmp_dir
    test "weak tag reacts to backing-file mtime; :pure does not", %{tmp_dir: dir} do
      path = Path.join(dir, "payload.bin")
      File.write!(path, <<0::size(1600)-unit(8)>>)
      slice = %FileSlice{path: path, offset: 0, length: 200}
      boxes = [%Box{type: "mdat", data: slice, size_mode: :compact}]

      stat1 = HTTP.etag(boxes, etag: :stat)
      pure1 = HTTP.etag(boxes, etag: :pure)
      assert String.starts_with?(stat1, "W/\"")

      File.touch!(path, {{2030, 1, 1}, {0, 0, 0}})

      assert HTTP.etag(boxes, etag: :pure) == pure1
      refute HTTP.etag(boxes, etag: :stat) == stat1
    end
  end
end
