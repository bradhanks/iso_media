defmodule PerfectPaper.Authz.RoleTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Authz.Role

  test "clears?/2 is true when held role is at or above required" do
    assert Role.clears?(:owner, :editor)
    assert Role.clears?(:editor, :editor)
    assert Role.clears?(:admin, :read |> Role.required_for())
  end

  test "clears?/2 is false when held role is below required" do
    refute Role.clears?(:viewer, :editor)
    refute Role.clears?(:commenter, :edit |> Role.required_for())
  end

  test "clears?/2 is false when held role is nil (no role at all)" do
    refute Role.clears?(nil, :viewer)
  end

  test "required_for/1 maps actions to the minimum role" do
    assert Role.required_for(:read) == :viewer
    assert Role.required_for(:comment) == :commenter
    assert Role.required_for(:edit) == :editor
    assert Role.required_for(:delete) == :admin
    assert Role.required_for(:share) == :admin
    assert Role.required_for(:manage_members) == :admin
  end

  test "mutating?/1 flags only audit-relevant actions" do
    assert Role.mutating?(:edit)
    assert Role.mutating?(:delete)
    assert Role.mutating?(:share)
    assert Role.mutating?(:manage_members)
    refute Role.mutating?(:read)
    refute Role.mutating?(:comment)
  end

  test "rank/1 raises ArgumentError for unknown roles" do
    assert_raise ArgumentError, ~r/unknown role/, fn -> Role.rank(:bogus) end
  end
end
