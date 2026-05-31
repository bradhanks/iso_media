defmodule ISOMedia.MovieBox do
  use Ecto.Schema
  import Ecto.Changeset

  schema "movie_boxes" do
    # required
    embeds_one(:mvhd, ISOMedia.MovieBox.MovieHeaderBox)
    # optional
    embeds_one(:meta, ISOMedia.MovieBox.MetaExtendsBox)
    # required
    embeds_many(:track_box, ISOMedia.MovieBox.TrackBox)
    embeds_one(:movie_extends_box, ISOMedia.MovieBox.MovieExtendsBox)
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:mvhd, :trak, :mvex])
    |> validate_required([:mvhd, :trak])
    |> cast_embed(:trak, with: &ISOMedia.TrakBox.changeset/2)
  end
end

defmodule ISOMedia.MovieBox.TrackBox do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field(:sample_count, :integer)
    field(:sample_offset, :integer)
  end
end

defmodule ISOMedia.TrakBox do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field(:tkhd, :map, required: true)
    field(:tref, :map)
    field(:mdia, ISOMedia.MdiaBox, required: true)
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:tkhd, :tref, :mdia])
    |> validate_required([:tkhd, :mdia])
    |> cast_embed(:mdia, with: &ISOMedia.MdiaBox.changeset/2)
  end
end

# Box Type: ‘mvhd’
# Container: Movie Box (‘moov’) Mandatory: Yes
# Quantity: Exactly one

defmodule ISOMedia.MovieBox.MovieHeaderBox do
  use Ecto.Schema

  embedded_schema do
  end
end

defmodule ISOMedia.MovieBox.TrackBox do
  use Ecto.Schema

  embedded_schema do
  end
end

# Box Type: ‘mvex’
# Container: Movie Box (‘moov’) Mandatory: No
# Quantity: Zero or one

defmodule ISOMedia.MovieBox.MetaExtendsBox do
  use Ecto.Schema

  embedded_schema do
  end
end
