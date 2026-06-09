defmodule ISOMedia.HTTP.DateTest do
  use ExUnit.Case, async: true

  alias ISOMedia.HTTP.Date

  describe "parse/1" do
    test "IMF-fixdate" do
      assert Date.parse("Sun, 06 Nov 1994 08:49:37 GMT") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "RFC 850" do
      assert Date.parse("Sunday, 06-Nov-94 08:49:37 GMT") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "asctime" do
      assert Date.parse("Sun Nov  6 08:49:37 1994") == {:ok, {{1994, 11, 6}, {8, 49, 37}}}
    end

    test "garbage is :error" do
      assert Date.parse("not a date") == :error
    end
  end

  describe "format/1 (IMF-fixdate)" do
    test "round-trips parse" do
      assert Date.format({{1994, 11, 6}, {8, 49, 37}}) == "Sun, 06 Nov 1994 08:49:37 GMT"
    end
  end
end
