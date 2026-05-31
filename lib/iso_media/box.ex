defmodule ISOMedia.Box do
  @moduledoc """
  A single generic ISOBMFF box.

  * `container = data: nil` with `children`
  * `leaf      = data: binary` with no children
  * `size_mode` records how the original size field was encoded so
    serialization can reproduce exact bytes.
  """

  defstruct type: nil, data: nil, children: [], uuid: nil, size_mode: :compact

  @type t :: %__MODULE__{
          type: String.t(),
          data: binary() | nil,
          children: [t()],
          uuid: <<_::128>> | nil,
          size_mode: :compact | :large | :eof
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
end
