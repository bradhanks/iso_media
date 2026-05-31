defmodule ISOMedia.FileTypeBox do
  use Ecto.Schema
  import Ecto.Changeset

  @doc false

  # Box Type: `ftyp’
  # Container: File
  # Mandatory: Yes
  # Quantity: Exactly one

  schema "file_type_boxes" do
    field(:major_brand, :string, required: true)
    field(:minor_version, :integer, required: true)
    field(:compatible_brands, {:array, :string}, required: true)
  end

  def changeset(file_type_box, params \\ %{}) do
    file_type
    |> cast(params, [:major_brand, :minor_version, :compatible_brands])
    |> validate_required([:major_brand, :minor_version, :compatible_brands])
    |> validate_format(:major_brand, ~r/^isom$/,
      message: "Only ISO Base Media files are supported."
    )
  end
  
  def from_binary(binary) do
    major_brand = String.slice(binary, 0, 4)
    minor_version = binary |> String.slice(4, 4) |> String.to_integer(16)
    compatible_brands = binary |> String.slice(8, 4) |> String.split()
    %ISOMedia.FileTypeBox{
      major_brand: major_brand,
      minor_version: minor_version,
      compatible_brands: compatible_brands
    }
  end
end
