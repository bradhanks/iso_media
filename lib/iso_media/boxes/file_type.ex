defmodule ISOMedia.Boxes.FileType do
  @moduledoc "Typed view of the `ftyp` File Type Box."

  alias ISOMedia.Box

  defstruct [:major_brand, :minor_version, :compatible_brands]

  @type t :: %__MODULE__{
          major_brand: String.t(),
          minor_version: non_neg_integer(),
          compatible_brands: [String.t()]
        }

  @doc "Decode an `ftyp` box into a `%FileType{}`."
  def decode(%Box{type: "ftyp", data: <<major::binary-size(4), minor::32, rest::binary>>}) do
    %__MODULE__{
      major_brand: major,
      minor_version: minor,
      compatible_brands: for(<<b::binary-size(4) <- rest>>, do: b)
    }
  end

  @doc "Encode a `%FileType{}` back into an `ftyp` box."
  def encode(%__MODULE__{} = ft) do
    data = IO.iodata_to_binary([ft.major_brand, <<ft.minor_version::32>>, ft.compatible_brands])
    %Box{type: "ftyp", data: data}
  end
end
