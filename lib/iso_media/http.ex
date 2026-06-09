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
  alias ISOMedia.HTTP.{Request, Resource}
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
    with box when not is_nil(box) <- Box.find(tree, ~w(ftyp)),
         %FileType{} = ft <- safe(fn -> FileType.decode(box) end) do
      [ft.major_brand | ft.compatible_brands]
    else
      _ -> []
    end
  end

  defp handler_types(tree) do
    tree
    |> all_boxes()
    |> Enum.filter(&(&1.type == "hdlr"))
    |> Enum.flat_map(fn box ->
      case safe(fn -> Handler.decode(box).handler_type end) do
        nil -> []
        type -> [type]
      end
    end)
  end

  # Decode helpers run against untrusted input; a malformed box degrades to "absent"
  # so content_type/1 stays total (falls through to application/mp4).
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp all_boxes(boxes) do
    Enum.flat_map(boxes, fn %Box{children: kids} = b -> [b | all_boxes(kids || [])] end)
  end

  @doc """
  Build a cacheable `%Resource{}` from a tree (or a prebuilt `SeekIndex`). Build once per
  `(file, validator)` and reuse across requests. With a bare `SeekIndex` (no tree), the
  content type defaults to `opts[:content_type] || "application/mp4"` (no tree to inspect).
  """
  @spec resource(SeekIndex.t() | Box.t() | [Box.t()], keyword()) :: Resource.t()
  def resource(index_or_tree, opts \\ [])

  def resource(%SeekIndex{} = idx, opts), do: build_resource(idx, nil, opts)

  def resource(tree, opts) do
    idx = SeekIndex.build(tree)
    build_resource(idx, tree, opts)
  end

  defp build_resource(idx, tree, opts) do
    %Resource{
      index: idx,
      etag: etag(idx, opts),
      last_modified: Keyword.get(opts, :last_modified),
      content_type: opts[:content_type] || derive_ct(tree, opts),
      content_length: SeekIndex.content_length(idx)
    }
  end

  defp derive_ct(nil, _opts), do: "application/mp4"

  defp derive_ct(tree, opts) do
    base = content_type(tree)
    if opts[:codecs], do: base <> ~s(; codecs="#{ISOMedia.Manifest.codecs(tree)}"), else: base
  end

  @doc "Normalize a header list/map + method into a `%Request{}` (lowercased header keys)."
  @spec from_headers([{binary(), binary()}] | map(), atom() | binary()) :: Request.t()
  def from_headers(headers, method) do
    h = normalize_headers(headers)

    %Request{
      method: normalize_method(method),
      range: h["range"],
      if_none_match: h["if-none-match"],
      if_match: h["if-match"],
      if_modified_since: h["if-modified-since"],
      if_unmodified_since: h["if-unmodified-since"],
      if_range: h["if-range"]
    }
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), v} end)
  end

  defp normalize_method(m) when is_atom(m), do: normalize_method(Atom.to_string(m))

  defp normalize_method(m) do
    case String.upcase(m) do
      "GET" -> :get
      "HEAD" -> :head
      _ -> :other
    end
  end
end
