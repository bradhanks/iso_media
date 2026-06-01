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
          data: binary() | nil,
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
  def read_data(%__MODULE__{data: %ISOMedia.FileSlice{} = slice}), do: ISOMedia.FileSlice.read(slice)
  def read_data(%__MODULE__{data: data}), do: data
end
