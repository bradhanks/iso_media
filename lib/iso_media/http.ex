defmodule ISOMedia.HTTP do
  @moduledoc """
  Pure, zero-dependency HTTP-semantics layer over `ISOMedia.SeekIndex`.

  Build a cacheable `resource/2`, normalize a request with `from_headers/2`, then `serve/2`
  to get a `%Response{}` plan; render it with `body_stream/2` (lazy, O(range)) or
  `body_iodata/1`. Validators come from `etag/2` and `content_type/1`. Nothing here opens a
  socket — see the optional `ISOMedia.Plug` for a transport adapter.
  """

  alias ISOMedia.Box
  alias ISOMedia.Boxes.{FileType, Handler}
  alias ISOMedia.SeekIndex

  defmodule Resource do
    @moduledoc "Precomputed, cacheable per-representation state."
    defstruct [:index, :etag, :last_modified, :content_type, :content_length]

    @type t :: %__MODULE__{
            index: ISOMedia.SeekIndex.t(),
            etag: binary(),
            last_modified: :calendar.datetime() | nil,
            content_type: binary(),
            content_length: non_neg_integer()
          }
  end

  defmodule Request do
    @moduledoc "Normalized inbound request fields."
    defstruct [
      :method,
      :range,
      :if_none_match,
      :if_match,
      :if_modified_since,
      :if_unmodified_since,
      :if_range
    ]

    @type t :: %__MODULE__{
            method: :get | :head | :other,
            range: binary() | nil,
            if_none_match: binary() | nil,
            if_match: binary() | nil,
            if_modified_since: binary() | nil,
            if_unmodified_since: binary() | nil,
            if_range: binary() | nil
          }
  end

  defmodule Response do
    @moduledoc "An HTTP response plan: status + headers + a pattern-matchable body spec."
    defstruct [:status, :headers, :body]

    @type body ::
            :empty
            | {:full, ISOMedia.SeekIndex.t()}
            | {:range, ISOMedia.SeekIndex.t(), non_neg_integer(), non_neg_integer()}
            | {:multipart, binary(), [map()], ISOMedia.SeekIndex.t()}

    @type t :: %__MODULE__{status: pos_integer(), headers: [{binary(), binary()}], body: body()}
  end

  @doc """
  A stable content fingerprint of a tree's serialization, computed from the `SeekIndex`
  descriptors (never the payload bytes of a slice). `:pure` (default) folds
  `{path, offset, length}` per slice + `:erlang.md5` of in-memory byte parts — a strong tag
  under the backing-files-immutable contract. `:stat` additionally folds each slice path's
  `mtime`+`size` (metadata I/O) and emits a weak `W/` tag.
  """
  @spec etag(SeekIndex.t() | ISOMedia.Box.t() | [ISOMedia.Box.t()], keyword()) :: binary()
  def etag(index_or_tree, opts \\ [])
  def etag(%SeekIndex{} = idx, opts), do: do_etag(idx, opts)
  def etag(tree, opts), do: do_etag(SeekIndex.build(tree), opts)

  defp do_etag(%SeekIndex{} = idx, opts) do
    mode = Keyword.get(opts, :etag, :pure)
    weak? = mode == :stat or Keyword.get(opts, :weak, false)

    digest =
      idx
      |> SeekIndex.providers()
      |> Enum.reduce(:erlang.md5_init(), &fold(&1, &2, mode))
      |> :erlang.md5_final()
      |> Base.encode16(case: :lower)

    if weak?, do: ~s(W/"#{digest}"), else: ~s("#{digest}")
  end

  defp fold({:bytes, bin}, ctx, _mode),
    do: :erlang.md5_update(ctx, [<<0, byte_size(bin)::64>>, bin])

  defp fold({:slice, fs}, ctx, :pure),
    do:
      :erlang.md5_update(ctx, [
        <<1, byte_size(fs.path)::64>>,
        fs.path,
        <<fs.offset::64, fs.length::64>>
      ])

  defp fold({:slice, fs}, ctx, :stat) do
    %File.Stat{size: size, mtime: mtime} = File.stat!(fs.path, time: :posix)

    :erlang.md5_update(ctx, [
      <<2, byte_size(fs.path)::64>>,
      fs.path,
      <<fs.offset::64, fs.length::64, size::64, mtime::64-signed>>
    ])
  end

  @heif_brands ~w(heic heix heim heis mif1)
  @avif_brands ~w(avif avis)

  @doc """
  Derive a media `Content-Type` from a tree's `ftyp` brands and track handler types.
  """
  @spec content_type([Box.t()] | Box.t()) :: binary()
  def content_type(%Box{} = box), do: content_type([box])

  def content_type(tree) when is_list(tree) do
    brands = brands(tree)
    handlers = handler_types(tree)

    cond do
      Box.find(tree, ~w(styp)) -> "video/iso.segment"
      "qt  " in brands -> "video/quicktime"
      Enum.any?(@avif_brands, &(&1 in brands)) -> "image/avif"
      Enum.any?(@heif_brands, &(&1 in brands)) and "pict" in handlers -> "image/heic"
      "vide" in handlers -> "video/mp4"
      "soun" in handlers -> "audio/mp4"
      true -> "application/mp4"
    end
  end

  defp brands(tree) do
    case Box.find(tree, ~w(ftyp)) do
      nil ->
        []

      box ->
        ft = FileType.decode(box)
        [ft.major_brand | ft.compatible_brands]
    end
  end

  defp handler_types(tree) do
    tree
    |> all_boxes()
    |> Enum.filter(&(&1.type == "hdlr"))
    |> Enum.map(&Handler.decode(&1).handler_type)
  end

  defp all_boxes(boxes) do
    Enum.flat_map(boxes, fn %Box{children: kids} = b -> [b | all_boxes(kids || [])] end)
  end
end
