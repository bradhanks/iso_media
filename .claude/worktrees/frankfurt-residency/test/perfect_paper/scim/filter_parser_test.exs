defmodule PerfectPaper.Scim.FilterParserTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Scim.FilterParser

  test "parses userName eq" do
    assert FilterParser.parse(~s(userName eq "alice@acme.com")) ==
             {:eq, :user_name, "alice@acme.com"}
  end

  test "parses externalId eq" do
    assert FilterParser.parse(~s(externalId eq "guid-123")) == {:eq, :external_id, "guid-123"}
  end

  test "parses displayName eq for groups" do
    assert FilterParser.parse(~s(displayName eq "Engineering")) ==
             {:eq, :display_name, "Engineering"}
  end

  test "attribute name is case-insensitive" do
    assert FilterParser.parse(~s(USERNAME EQ "x@acme.com")) == {:eq, :user_name, "x@acme.com"}
  end

  test "strips a fully-qualified schema URN prefix (Entra)" do
    assert FilterParser.parse(
             ~s(urn:ietf:params:scim:schemas:core:2.0:User:userName eq "alice@acme.com")
           ) == {:eq, :user_name, "alice@acme.com"}
  end

  test "empty or nil filter -> :no_match (never raises)" do
    assert FilterParser.parse("") == :no_match
    assert FilterParser.parse(nil) == :no_match
  end

  test "unsupported operator/compound/garbage -> :no_match (never raises)" do
    assert FilterParser.parse(~s(userName co "ali")) == :no_match
    assert FilterParser.parse(~s(userName eq "a" and active eq true)) == :no_match
    assert FilterParser.parse("garbage(((") == :no_match
  end
end
