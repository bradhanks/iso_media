defmodule PerfectPaper.Scim.PatchParserTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Scim.PatchParser

  test "path-targeted active:false (stringified)" do
    body = %{"Operations" => [%{"op" => "replace", "path" => "active", "value" => "false"}]}
    assert {:ok, ops} = PatchParser.parse(body)
    assert {:set_active, false} in ops
  end

  test "value-targeted active:false (literal)" do
    body = %{"Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]}
    assert {:ok, ops} = PatchParser.parse(body)
    assert {:set_active, false} in ops
  end

  test "active:true literal and stringified both normalize" do
    assert {:ok, [{:set_active, true}]} =
             PatchParser.parse(%{
               "Operations" => [%{"op" => "replace", "path" => "active", "value" => "True"}]
             })

    assert {:ok, [{:set_active, true}]} =
             PatchParser.parse(%{
               "Operations" => [%{"op" => "replace", "value" => %{"active" => true}}]
             })
  end

  test "add/remove members ops" do
    add = %{
      "Operations" => [
        %{"op" => "add", "path" => "members", "value" => [%{"value" => "u1"}, %{"value" => "u2"}]}
      ]
    }

    assert {:ok, [{:add_members, ["u1", "u2"]}]} = PatchParser.parse(add)

    rm = %{
      "Operations" => [%{"op" => "remove", "path" => "members", "value" => [%{"value" => "u1"}]}]
    }

    assert {:ok, [{:remove_members, ["u1"]}]} = PatchParser.parse(rm)
  end

  test "displayName rename" do
    body = %{
      "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "New Name"}]
    }

    assert {:ok, [{:set_display_name, "New Name"}]} = PatchParser.parse(body)
  end

  test "op is case-insensitive (REPLACE / ADD)" do
    deact = %{"Operations" => [%{"op" => "REPLACE", "path" => "active", "value" => "false"}]}
    assert {:ok, [{:set_active, false}]} = PatchParser.parse(deact)

    add = %{
      "Operations" => [%{"op" => "Add", "path" => "members", "value" => [%{"value" => "u1"}]}]
    }

    assert {:ok, [{:add_members, ["u1"]}]} = PatchParser.parse(add)
  end

  test "combined add + remove in one body normalizes both" do
    body = %{
      "Operations" => [
        %{"op" => "add", "path" => "members", "value" => [%{"value" => "a"}]},
        %{"op" => "remove", "path" => "members", "value" => [%{"value" => "b"}]}
      ]
    }

    assert {:ok, [{:add_members, ["a"]}, {:remove_members, ["b"]}]} = PatchParser.parse(body)
  end

  test "missing/invalid Operations -> error (controller maps to 400 invalidSyntax)" do
    assert {:error, :invalid_syntax} = PatchParser.parse(%{})
    assert {:error, :invalid_syntax} = PatchParser.parse(%{"Operations" => "nope"})
  end
end
