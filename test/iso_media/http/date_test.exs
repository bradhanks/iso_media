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

    test "invalid calendar date is :error" do
      assert Date.parse("Wed, 30 Feb 1994 08:49:37 GMT") == :error
    end

    test "asctime with a two-digit day" do
      assert Date.parse("Sat Nov 16 08:49:37 1994") == {:ok, {{1994, 11, 16}, {8, 49, 37}}}
    end

    test "RFC 850 two-digit year window (69 => 2069, 70 => 1970)" do
      assert Date.parse("Sunday, 01-Jan-69 00:00:00 GMT") == {:ok, {{2069, 1, 1}, {0, 0, 0}}}
      assert Date.parse("Thursday, 01-Jan-70 00:00:00 GMT") == {:ok, {{1970, 1, 1}, {0, 0, 0}}}
    end

    test "non-binary input is :error, never raises" do
      assert Date.parse(nil) == :error
      assert Date.parse(12_345) == :error
    end
  end

  describe "format/1 (IMF-fixdate)" do
    test "round-trips parse" do
      assert Date.format({{1994, 11, 6}, {8, 49, 37}}) == "Sun, 06 Nov 1994 08:49:37 GMT"
    end
  end
end
