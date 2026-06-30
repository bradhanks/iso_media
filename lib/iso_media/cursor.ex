defmodule ISOMedia.Cursor do
  @moduledoc """
  A zipper for surgical edits to one box deep in a tree.

  `Box.find`/`update` operate on *every* box matching a type-path; a `Cursor` instead
  focuses **one specific** box — the Nth of a type along a path — so you can read it, edit
  it in place, walk to its parent, or remove it, and then rebuild the whole tree with only
  that change applied. This is the "give me this box, its parent, and a put-back" layer for
  chopping a tree apart and reassembling it.

      iex> {:ok, boxes} = ISOMedia.parse(file)
      iex> boxes
      ...> |> ISOMedia.Cursor.at(["moov", {"trak", 1}, "tkhd"])   # the 2nd trak's tkhd
      ...> |> ISOMedia.Cursor.update(&flag_enabled/1)
      ...> |> ISOMedia.Cursor.tree()                              # rebuilt [%Box{}]

  A path segment is either a type string `"trak"` (the first such child) or a
  `{type, index}` tuple `{"trak", 1}` (the zero-based Nth such child). `at/2` returns `nil`
  if the path does not resolve, so it composes with `||`.
  """

  alias ISOMedia.Box

  @enforce_keys [:focus, :crumbs]
  defstruct [:focus, :crumbs]

  @typedoc "A path segment: a type, or `{type, zero-based index}`."
  @type segment :: String.t() | {String.t(), non_neg_integer()}

  # A crumb records, for one level, the focus's siblings (in document order) and the parent
  # box whose `children` they are — or `:root` when the focus is a top-level box.
  @type crumb :: %{left: [Box.t()], right: [Box.t()], parent: Box.t() | :root}
  @type t :: %__MODULE__{focus: Box.t(), crumbs: [crumb()]}

  @doc "Focus the box reached by `path` (see the module doc), or `nil` if it does not resolve."
  @spec at([Box.t()], [segment()]) :: t() | nil
  def at(boxes, path) when is_list(boxes) and is_list(path), do: enter(boxes, :root, [], path)

  defp enter(_siblings, _parent, _crumbs, []), do: nil

  defp enter(siblings, parent, crumbs, [seg | rest]) do
    {type, index} = normalize(seg)

    case nth_index(siblings, type, index) do
      nil ->
        nil

      i ->
        {left, [focus | right]} = Enum.split(siblings, i)
        crumbs = [%{left: left, right: right, parent: parent} | crumbs]

        if rest == [] do
          %__MODULE__{focus: focus, crumbs: crumbs}
        else
          enter(focus.children, focus, crumbs, rest)
        end
    end
  end

  defp normalize({type, index}) when is_binary(type) and is_integer(index) and index >= 0,
    do: {type, index}

  defp normalize(type) when is_binary(type), do: {type, 0}

  # Index of the `index`-th (0-based) box of `type` in `siblings`, or nil.
  defp nth_index(siblings, type, index) do
    siblings
    |> Enum.with_index()
    |> Enum.filter(fn {box, _i} -> box.type == type end)
    |> Enum.at(index)
    |> case do
      {_box, i} -> i
      nil -> nil
    end
  end

  @doc "The box currently in focus."
  @spec focus(t()) :: Box.t()
  def focus(%__MODULE__{focus: box}), do: box

  @doc "Replace the focused box (keeps the cursor focused on the replacement)."
  @spec replace(t(), Box.t()) :: t()
  def replace(%__MODULE__{} = cursor, %Box{} = box), do: %{cursor | focus: box}

  @doc "Apply `fun` to the focused box (keeps the cursor focused on the result)."
  @spec update(t(), (Box.t() -> Box.t())) :: t()
  def update(%__MODULE__{focus: box} = cursor, fun), do: %{cursor | focus: fun.(box)}

  @doc "Move focus to the parent container, or `nil` when the focus is already top-level."
  @spec up(t()) :: t() | nil
  def up(%__MODULE__{crumbs: [%{parent: :root}]}), do: nil

  def up(%__MODULE__{focus: focus, crumbs: [%{parent: parent, left: l, right: r} | rest]}) do
    %__MODULE__{focus: %{parent | children: l ++ [focus] ++ r}, crumbs: rest}
  end

  @doc "Rebuild and return the whole tree (the top-level box list) with the focused edits applied."
  @spec tree(t()) :: [Box.t()]
  def tree(%__MODULE__{focus: focus, crumbs: crumbs}), do: rebuild(focus, crumbs)

  defp rebuild(node, [%{parent: :root, left: l, right: r}]), do: l ++ [node] ++ r

  defp rebuild(node, [%{parent: parent, left: l, right: r} | rest]) do
    rebuild(%{parent | children: l ++ [node] ++ r}, rest)
  end

  @doc """
  Remove the focused box and return the rebuilt tree (the top-level box list). The focus
  is consumed; obtain a new cursor from the returned tree if you need to keep editing.
  """
  @spec remove(t()) :: [Box.t()]
  def remove(%__MODULE__{crumbs: [%{parent: :root, left: l, right: r}]}), do: l ++ r

  def remove(%__MODULE__{crumbs: [%{parent: parent, left: l, right: r} | rest]}) do
    rebuild(%{parent | children: l ++ r}, rest)
  end
end
