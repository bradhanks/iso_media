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
end
