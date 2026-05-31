defmodule ISOMedia.FixturesTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.FileType

  @fixtures Path.wildcard(Path.join([__DIR__, "..", "fixtures", "*.{mp4,m4a}"]))

  test "fixtures exist" do
    assert @fixtures != [], "expected generated fixtures in test/fixtures (run ffmpeg step)"
  end

  for path <- @fixtures do
    @path path

    test "round-trips real file byte-for-byte: #{Path.basename(path)}" do
      original = File.read!(@path)
      {:ok, boxes} = ISOMedia.parse(original)
      assert ISOMedia.serialize(boxes) == original
    end

    test "has a top-level ftyp that decodes: #{Path.basename(path)}" do
      {:ok, boxes} = ISOMedia.parse(File.read!(@path))
      ftyp = Box.find(boxes, ~w(ftyp))
      assert %Box{type: "ftyp"} = ftyp
      decoded = FileType.decode(ftyp)
      assert byte_size(decoded.major_brand) == 4
    end
  end
end
