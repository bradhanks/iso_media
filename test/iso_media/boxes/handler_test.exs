defmodule ISOMedia.Boxes.HandlerTest do
  use ExUnit.Case
  alias ISOMedia.Box
  alias ISOMedia.Boxes.Handler

  # FullBox(v0,flags0) + pre_defined(0) + handler "vide" + 3x reserved + name "VideoHandler\0"
  @data <<0, 0, 0, 0, 0::32, "vide", 0::32, 0::32, 0::32, "VideoHandler", 0>>

  test "decode/1 extracts handler_type and name (name strips trailing NUL)" do
    h = Handler.decode(%Box{type: "hdlr", data: @data})
    assert h.handler_type == "vide"
    assert h.name == "VideoHandler"
    assert h.version == 0
  end

  test "encode/1 round-trips back to the original box data" do
    box = %Box{type: "hdlr", data: @data}
    assert Handler.encode(Handler.decode(box)) == box
  end

  test "round-trips a name field with no trailing NUL" do
    data = <<0, 0, 0, 0, 0::32, "vide", 0::32, 0::32, 0::32, "VideoHandler">>
    box = %Box{type: "hdlr", data: data}
    assert Handler.encode(Handler.decode(box)) == box
  end

  test "round-trips a name field with an embedded NUL and trailing bytes" do
    data = <<0, 0, 0, 0, 0::32, "vide", 0::32, 0::32, 0::32, "abc", 0, "def">>
    box = %Box{type: "hdlr", data: data}
    assert Handler.decode(box).name == "abc"
    assert Handler.encode(Handler.decode(box)) == box
  end
end
