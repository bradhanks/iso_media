defmodule ISOMedia.RoundtripPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias ISOMedia.{Box, Serializer, Parser}

  # A printable 4-char type that is NOT a known container, so the parser keeps
  # it as a leaf and round-trips deterministically.
  defp leaf_type do
    gen all <<a, b, c, d>> <- binary(length: 4),
            type = <<rescale(a), rescale(b), rescale(c), rescale(d)>>,
            not ISOMedia.Registry.container?(type) do
      type
    end
  end

  # map a byte into the printable ASCII range 0x41..0x5A (A-Z)
  defp rescale(byte), do: 0x41 + rem(byte, 26)

  defp leaf_box do
    gen all type <- leaf_type(),
            data <- binary(max_length: 32) do
      %Box{type: type, data: data, size_mode: :compact}
    end
  end

  defp container_box do
    gen all type <- leaf_type(),
            kids <- list_of(leaf_box(), max_length: 3) do
      %Box{type: type, data: nil, children: kids, size_mode: :compact}
    end
  end

  property "serialize |> parse is identity for generated trees" do
    check all boxes <- list_of(one_of([leaf_box(), container_box()]), max_length: 5) do
      bin = Serializer.serialize(boxes)
      assert {:ok, parsed} = Parser.parse(bin, heuristic: false)
      assert Serializer.serialize(parsed) == bin
    end
  end
end
