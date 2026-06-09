defmodule ISOMedia.Box do
  @moduledoc """
  A single generic ISOBMFF box.

  * `container = data: nil` with `children`
  * `leaf      = data: binary` with no children
  * `size_mode` records how the original size field was encoded so
    serialization can reproduce exact bytes.
  """

  defstruct type: nil,
            data: nil,
            children: [],
            uuid: nil,
            size_mode: :compact,
            source_offset: nil,
            source_size: nil

  @type t :: %__MODULE__{
          type: String.t(),
          data: binary() | ISOMedia.FileSlice.t() | [binary() | ISOMedia.FileSlice.t()] | nil,
          children: [t()],
          uuid: <<_::128>> | nil,
          size_mode: :compact | :large | :eof,
          source_offset: non_neg_integer() | nil,
          source_size: non_neg_integer() | nil
        }

  @doc "True when the box holds child boxes rather than a raw payload."
  def container?(%__MODULE__{data: nil}), do: true
  def container?(%__MODULE__{}), do: false

  @doc "True when the box holds a raw payload rather than children."
  def leaf?(%__MODULE__{data: nil}), do: false
  def leaf?(%__MODULE__{}), do: true

  @doc """
  Build a leaf box (raw payload, no children). `data` is a binary, an `ISOMedia.FileSlice`,
  or a recursive segment list. `opts` may set `:uuid` and `:size_mode` (default `:compact`).
  """
  @spec leaf(String.t(), binary() | ISOMedia.FileSlice.t() | list(), keyword()) :: t()
  def leaf(type, data, opts \\ []) do
    %__MODULE__{
      type: type,
      data: data,
      uuid: Keyword.get(opts, :uuid),
      size_mode: Keyword.get(opts, :size_mode, :compact)
    }
  end

  @doc """
  Build a container box (child boxes, no payload). `children` defaults to `[]`. `opts` may set
  `:uuid` and `:size_mode` (default `:compact`).
  """
  @spec container(String.t(), [t()], keyword()) :: t()
  def container(type, children \\ [], opts \\ []) do
    %__MODULE__{
      type: type,
      data: nil,
      children: children,
      uuid: Keyword.get(opts, :uuid),
      size_mode: Keyword.get(opts, :size_mode, :compact)
    }
  end

  @doc """
  Convenience constructor dispatching on the second argument: a binary or `ISOMedia.FileSlice`
  builds a leaf; a list of boxes (or an empty list) builds a container. Raises on an ambiguous
  list (e.g. a raw segment-list payload) — use `leaf/3` or `container/3` explicitly there.
  """
  @spec new(String.t(), binary() | ISOMedia.FileSlice.t() | [t()]) :: t()
  def new(type, data) when is_binary(data), do: leaf(type, data)
  def new(type, %ISOMedia.FileSlice{} = data), do: leaf(type, data)

  def new(type, children) when is_list(children) do
    if Enum.all?(children, &is_struct(&1, __MODULE__)) do
      container(type, children)
    else
      raise ArgumentError,
            "Box.new/2: ambiguous list for #{inspect(type)}; " <>
              "use Box.leaf/3 or Box.container/3 explicitly"
    end
  end

  # --- size encoding ---

  # The largest value the 32-bit compact `size` field can hold. A box whose total
  # serialized length exceeds this must use the 64-bit `largesize` form (`:large`).
  @uint32_max 0xFFFFFFFF

  @doc """
  The `size_mode` a freshly built box needs to encode a body of `body_size` bytes
  (where `body_size` counts the `uuid` bytes plus the payload/children, i.e. everything
  after the 8-byte size+type header). Returns `:large` when the compact 32-bit `size`
  field would overflow, otherwise `:compact`. This is the single source of truth for the
  compact↔large decision — builders use it to stamp synthesized boxes, and the serializer
  uses it to refuse to emit a truncated size field.
  """
  @spec size_mode_for_body(non_neg_integer()) :: :compact | :large
  def size_mode_for_body(body_size) when is_integer(body_size) and body_size >= 0 do
    if 8 + body_size > @uint32_max, do: :large, else: :compact
  end

  @doc "Byte length of the size+type header for a `size_mode` (before any uuid): 8 or 16."
  @spec header_base(:compact | :large | :eof) :: 8 | 16
  def header_base(:compact), do: 8
  def header_base(:large), do: 16
  def header_base(:eof), do: 8

  @doc "Return the first box matching the type-path, or `nil`."
  def find(boxes, path) when is_list(boxes), do: boxes |> find_all(path) |> List.first()

  @doc "Return every box matching the type-path."
  def find_all(boxes, [type]) when is_list(boxes) do
    Enum.filter(boxes, &(&1.type == type))
  end

  def find_all(boxes, [type | rest]) when is_list(boxes) do
    boxes
    |> Enum.filter(&(&1.type == type))
    |> Enum.flat_map(&find_all(&1.children, rest))
  end

  @doc "Apply `fun` to every box matching the type-path; returns a new tree."
  def update(boxes, [type], fun) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type, do: fun.(box), else: box
    end)
  end

  def update(boxes, [type | rest], fun) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type and box.data == nil do
        %{box | children: update(box.children, rest, fun)}
      else
        box
      end
    end)
  end

  @doc "Remove every box matching the type-path; returns a new tree."
  def remove(boxes, [type]) when is_list(boxes) do
    Enum.reject(boxes, &(&1.type == type))
  end

  def remove(boxes, [type | rest]) when is_list(boxes) do
    Enum.map(boxes, fn box ->
      if box.type == type and box.data == nil do
        %{box | children: remove(box.children, rest)}
      else
        box
      end
    end)
  end

  @doc """
  Insert `new_box` into the children of the container found at `path`.
  `at` is `:start`, `:end`, or a zero-based integer index.
  """
  def insert(boxes, path, new_box, at \\ :end) when is_list(boxes) do
    update(boxes, path, fn
      %__MODULE__{data: nil} = container ->
        %{container | children: splice(container.children, new_box, at)}

      %__MODULE__{type: type} ->
        raise ArgumentError,
              "cannot insert into leaf box #{inspect(type)} (it has a data payload, not children)"
    end)
  end

  defp splice(children, box, :end), do: children ++ [box]
  defp splice(children, box, :start), do: [box | children]

  defp splice(children, box, index) when is_integer(index) do
    {pre, post} = Enum.split(children, index)
    pre ++ [box] ++ post
  end

  @doc "Replace a box's payload, making it a leaf (drops any children)."
  def replace_data(%__MODULE__{} = box, binary) when is_binary(binary) do
    %{box | data: binary, children: []}
  end

  @doc """
  Return a leaf box's payload bytes, reading the file if it's a `FileSlice`.
  Returns `nil` for a container.
  """
  def read_data(%__MODULE__{data: %ISOMedia.FileSlice{} = slice}),
    do: ISOMedia.FileSlice.read(slice)

  def read_data(%__MODULE__{data: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      %ISOMedia.FileSlice{} = s -> ISOMedia.FileSlice.read(s)
      bin when is_binary(bin) -> bin
    end)
    |> IO.iodata_to_binary()
  end

  def read_data(%__MODULE__{data: data}), do: data
end
