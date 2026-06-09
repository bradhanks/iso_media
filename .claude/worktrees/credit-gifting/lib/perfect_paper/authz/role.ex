defmodule PerfectPaper.Authz.Role do
  @moduledoc """
  The fixed role ladder for Spec 1 authorization and the action→role mapping.

  Roles are totally ordered: `:viewer < :commenter < :editor < :admin < :owner`.
  A held role "clears" an action when it sits at or above the action's minimum.
  """

  @ladder [:viewer, :commenter, :editor, :admin, :owner]

  @required %{
    read: :viewer,
    comment: :commenter,
    edit: :editor,
    delete: :admin,
    share: :admin,
    manage_members: :admin
  }

  @mutating [:edit, :delete, :share, :manage_members]

  @type t :: :viewer | :commenter | :editor | :admin | :owner
  @type action :: :read | :comment | :edit | :delete | :share | :manage_members

  @doc "The minimum role required to perform `action`."
  @spec required_for(action()) :: t()
  def required_for(action), do: Map.fetch!(@required, action)

  @doc "Whether `held` role sits at or above `required`. `nil` held never clears."
  @spec clears?(t() | nil, t()) :: boolean()
  def clears?(nil, _required), do: false

  def clears?(held, required) do
    rank(held) >= rank(required)
  end

  @doc "Whether `action` is audit-logged (mutating) in Spec 1."
  @spec mutating?(action()) :: boolean()
  def mutating?(action), do: action in @mutating

  @doc "Numeric rank of a role on the ladder (0 = lowest). Public for max_by."
  @spec rank(t()) :: non_neg_integer()
  def rank(role) when role in @ladder, do: Enum.find_index(@ladder, &(&1 == role))
  def rank(role), do: raise(ArgumentError, "unknown role: #{inspect(role)}")
end
