defmodule ISOMedia.HTTP.ContentTypeTest do
  use ExUnit.Case, async: true

  alias ISOMedia.{Box, HTTP}
  alias ISOMedia.Boxes.{FileType, Handler}

  defp ftyp(major, compat \\ []),
    do:
      FileType.encode(%FileType{major_brand: major, minor_version: 0, compatible_brands: compat})

  defp hdlr(type),
    do:
      Handler.encode(%Handler{
        version: 0,
        flags: <<0::24>>,
        handler_type: type,
        name: "",
        name_suffix: ""
      })

  defp moov_with(handler),
    do: Box.container("moov", [Box.container("trak", [Box.container("mdia", [handler])])])

  test "video track => video/mp4" do
    assert HTTP.content_type([ftyp("isom"), moov_with(hdlr("vide"))]) == "video/mp4"
  end

  test "audio-only => audio/mp4" do
    assert HTTP.content_type([ftyp("M4A "), moov_with(hdlr("soun"))]) == "audio/mp4"
  end

  test "quicktime brand => video/quicktime" do
    assert HTTP.content_type([ftyp("qt  "), moov_with(hdlr("vide"))]) == "video/quicktime"
  end

  test "heic image => image/heic" do
    assert HTTP.content_type([ftyp("heic", ["mif1"]), moov_with(hdlr("pict"))]) == "image/heic"
  end

  test "top-level styp => video/iso.segment" do
    assert HTTP.content_type([%Box{type: "styp", data: <<"msdh">>, size_mode: :compact}]) ==
             "video/iso.segment"
  end

  test "no recognizable structure => application/mp4" do
    assert HTTP.content_type([%Box{type: "free", data: <<>>, size_mode: :compact}]) ==
             "application/mp4"
  end
end
