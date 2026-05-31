defmodule ISOMedia.Boxes.FileTypeTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.FileType

  @data <<"isom", 512::32, "isom", "iso2", "mp41">>

  test "decode/1 extracts brands and minor version" do
    ft = FileType.decode(%Box{type: "ftyp", data: @data})
    assert ft.major_brand == "isom"
    assert ft.minor_version == 512
    assert ft.compatible_brands == ["isom", "iso2", "mp41"]
  end

  test "encode/1 round-trips back to the original box data" do
    box = %Box{type: "ftyp", data: @data}
    assert FileType.encode(FileType.decode(box)) == box
  end
end
