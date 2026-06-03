defmodule ISOMedia.BoxPath do
  @moduledoc """
  Navigate and update a single box by a child-type path. Shared by `Extract`, `Trim`,
  and `Concat` (which all walk `trak`/`mdia`/`minf`/`stbl` subtrees).
  """

  alias ISOMedia.Box

  @doc "The descendant of `box` reached by following the child-type `path`, or nil."
  def dig(%Box{type: type} = box, path), do: Box.find([box], [type | path])

  @doc "Apply `fun` to the descendant(s) of `box` at `path`; returns the updated box."
  def update_descendant(box, [], fun), do: fun.(box)

  def update_descendant(%Box{children: children} = box, [type | rest], fun) do
    new_children =
      Enum.map(children, fn
        %Box{type: ^type} = c -> update_descendant(c, rest, fun)
        other -> other
      end)

    %{box | children: new_children}
  end
end
