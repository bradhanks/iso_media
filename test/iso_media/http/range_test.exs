defmodule ISOMedia.HTTP.RangeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ISOMedia.HTTP.Range

  describe "parse/3 — spec forms" do
    test "single closed range" do
      assert Range.parse("bytes=0-499", 1000) == {:ok, [{0, 499}]}
    end

    test "open-ended range clamps to last byte" do
      assert Range.parse("bytes=500-", 1000) == {:ok, [{500, 999}]}
    end

    test "suffix range counts from the end" do
      assert Range.parse("bytes=-500", 1000) == {:ok, [{500, 999}]}
    end

    test "suffix larger than total yields the whole resource" do
      assert Range.parse("bytes=-5000", 1000) == {:ok, [{0, 999}]}
    end

    test "last clamps to total-1" do
      assert Range.parse("bytes=900-5000", 1000) == {:ok, [{900, 999}]}
    end
  end

  describe "parse/3 — multi, coalescing, satisfiability" do
    test "multiple disjoint ranges sorted" do
      assert Range.parse("bytes=200-299,0-99", 1000) == {:ok, [{0, 99}, {200, 299}]}
    end

    test "overlapping/adjacent ranges coalesce" do
      assert Range.parse("bytes=0-99,100-199,150-250", 1000) == {:ok, [{0, 250}]}
    end

    test "all-out-of-range is unsatisfiable" do
      assert Range.parse("bytes=2000-3000", 1000) == :unsatisfiable
    end

    test "suffix of zero is unsatisfiable" do
      assert Range.parse("bytes=-0", 1000) == :unsatisfiable
    end

    test "mix of satisfiable + unsatisfiable keeps the satisfiable one" do
      assert Range.parse("bytes=0-99,5000-6000", 1000) == {:ok, [{0, 99}]}
    end
  end

  describe "parse/3 — ignore (serve 200)" do
    test "non-bytes unit is ignored" do
      assert Range.parse("items=0-10", 1000) == :ignore
    end

    test "syntactic garbage ignores the whole header" do
      assert Range.parse("bytes=abc-def", 1000) == :ignore
      assert Range.parse("bytes=10-5", 1000) == :ignore
      assert Range.parse("bytes=", 1000) == :ignore
    end

    test "more ranges than the cap is ignored" do
      header = "bytes=" <> Enum.map_join(0..200, ",", fn i -> "#{i * 10}-#{i * 10 + 1}" end)
      assert Range.parse(header, 1_000_000, max_ranges: 100) == :ignore
    end

    test "a leading plus sign is a syntax error, not a number" do
      assert Range.parse("bytes=+5-10", 1000) == :ignore
      assert Range.parse("bytes=5-+10", 1000) == :ignore
      assert Range.parse("bytes=-+5", 1000) == :ignore
    end
  end

  describe "parse/3 — never raises (invariant #8)" do
    property "arbitrary header strings only ever return {:ok,_} | :unsatisfiable | :ignore" do
      check all(header <- string(:printable, max_length: 60), total <- integer(0..10_000)) do
        result = Range.parse("bytes=" <> header, total)

        case result do
          {:ok, ranges} ->
            assert Enum.all?(ranges, fn {f, l} -> f >= 0 and l < total and f <= l end)

          other ->
            assert other in [:unsatisfiable, :ignore]
        end
      end
    end
  end
end
