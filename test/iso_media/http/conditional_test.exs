defmodule ISOMedia.HTTP.ConditionalTest do
  use ExUnit.Case, async: true

  alias ISOMedia.HTTP.{Conditional, Request, Resource}

  @etag ~s("v1")
  @lm {{2024, 1, 1}, {12, 0, 0}}
  @res %Resource{
    index: nil,
    etag: @etag,
    last_modified: @lm,
    content_type: "video/mp4",
    content_length: 100
  }

  defp req(fields), do: struct(%Request{method: :get}, fields)

  describe "evaluate/2 precedence" do
    test "If-Match mismatch => precondition_failed (step 1)" do
      assert Conditional.evaluate(req(if_match: ~s("other")), @res) == :precondition_failed
    end

    test "If-Match * matches existing resource => proceed" do
      assert Conditional.evaluate(req(if_match: "*"), @res) == :proceed
    end

    test "If-Unmodified-Since older than mtime => precondition_failed (step 2)" do
      assert Conditional.evaluate(req(if_unmodified_since: "Mon, 01 Jan 2024 11:00:00 GMT"), @res) ==
               :precondition_failed
    end

    test "If-None-Match match + GET => not_modified (step 3)" do
      assert Conditional.evaluate(req(if_none_match: @etag), @res) == :not_modified
    end

    test "If-None-Match match + non-GET => precondition_failed" do
      assert Conditional.evaluate(req(method: :other, if_none_match: @etag), @res) ==
               :precondition_failed
    end

    test "If-None-Match uses weak comparison" do
      assert Conditional.evaluate(req(if_none_match: ~s(W/"v1")), @res) == :not_modified
    end

    test "If-Modified-Since not modified => not_modified (step 4)" do
      assert Conditional.evaluate(req(if_modified_since: "Mon, 01 Jan 2024 12:00:00 GMT"), @res) ==
               :not_modified
    end

    test "If-Modified-Since older than mtime => proceed" do
      assert Conditional.evaluate(req(if_modified_since: "Mon, 01 Jan 2024 11:00:00 GMT"), @res) ==
               :proceed
    end

    test "If-Match takes precedence over If-None-Match" do
      assert Conditional.evaluate(req(if_match: ~s("other"), if_none_match: @etag), @res) ==
               :precondition_failed
    end

    test "no conditions => proceed" do
      assert Conditional.evaluate(req([]), @res) == :proceed
    end
  end

  describe "if_range_satisfied?/2" do
    test "absent If-Range is satisfied" do
      assert Conditional.if_range_satisfied?(req([]), @res)
    end

    test "matching strong etag satisfied; mismatch not" do
      assert Conditional.if_range_satisfied?(req(if_range: @etag), @res)
      refute Conditional.if_range_satisfied?(req(if_range: ~s("other")), @res)
    end

    test "weak etag is NOT a valid If-Range validator" do
      refute Conditional.if_range_satisfied?(req(if_range: ~s(W/"v1")), @res)
    end

    test "date If-Range satisfied when not modified since" do
      assert Conditional.if_range_satisfied?(req(if_range: "Mon, 01 Jan 2024 12:00:00 GMT"), @res)
      refute Conditional.if_range_satisfied?(req(if_range: "Mon, 01 Jan 2024 11:00:00 GMT"), @res)
    end
  end
end
