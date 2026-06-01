defmodule ISOMedia.LayoutTest do
  use ExUnit.Case
  alias ISOMedia.{Box, Layout}

  test "header_size accounts for size_mode and uuid" do
    assert Layout.header_size(%Box{size_mode: :compact}) == 8
    assert Layout.header_size(%Box{size_mode: :large}) == 16
    assert Layout.header_size(%Box{size_mode: :eof}) == 8
    assert Layout.header_size(%Box{size_mode: :compact, uuid: <<0::128>>}) == 24
  end

  test "box_size matches the serializer's byte length" do
    box = %Box{type: "free", data: <<1, 2, 3, 4>>}
    assert Layout.box_size(box) == byte_size(ISOMedia.Serializer.serialize(box))

    nested = %Box{type: "moov", children: [%Box{type: "free", data: <<0>>}]}
    assert Layout.box_size(nested) == byte_size(ISOMedia.Serializer.serialize(nested))
  end

  test "top_level_layout gives absolute offset and payload_offset per box" do
    boxes = [
      %Box{type: "ftyp", data: <<0, 0, 0, 0>>},
      %Box{type: "mdat", data: <<9, 9, 9>>}
    ]

    [ftyp, mdat] = Layout.top_level_layout(boxes)
    assert ftyp.offset == 0
    assert ftyp.payload_offset == 8
    # ftyp box is 8 + 4 = 12 bytes
    assert mdat.offset == 12
    assert mdat.payload_offset == 20
  end

  test "box_size counts a FileSlice payload by its length" do
    slice = %ISOMedia.FileSlice{path: "irrelevant", offset: 0, length: 5000}
    box = %Box{type: "mdat", data: slice}
    # compact header (8) + slice length (5000)
    assert Layout.box_size(box) == 5008
  end
end
