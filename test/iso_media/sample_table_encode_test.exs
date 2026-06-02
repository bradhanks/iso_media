defmodule ISOMedia.SampleTableEncodeTest do
  use ExUnit.Case
  alias ISOMedia.SampleTable

  test "build_stts run-length-encodes durations" do
    box = SampleTable.build_stts([100, 100, 40])
    assert box.type == "stts"
    # version/flags(4) + count(2 entries) + {2,100} {1,40}
    assert box.data == <<0, 0, 0, 0, 2::32, 2::32, 100::32, 1::32, 40::32>>
  end

  test "build_stsz writes explicit sizes" do
    box = SampleTable.build_stsz([10, 20, 30])
    assert box.data == <<0, 0, 0, 0, 0::32, 3::32, 10::32, 20::32, 30::32>>
  end

  test "build_ctts returns nil when all offsets are zero" do
    assert SampleTable.build_ctts([0, 0, 0]) == nil
  end

  test "build_ctts (v0) RLEs nonnegative offsets" do
    box = SampleTable.build_ctts([5, 5, 0])
    assert box.type == "ctts"
    assert box.data == <<0, 0, 0, 0, 2::32, 2::32, 5::32, 1::32, 0::32>>
  end

  test "build_ctts (v1) uses signed offsets when any is negative" do
    box = SampleTable.build_ctts([-2, 3])
    assert <<1::8, 0::24, 2::32, 1::32, -2::signed-32, 1::32, 3::signed-32>> = box.data
  end

  test "build_stss writes 1-based sync positions" do
    box = SampleTable.build_stss([1, 4])
    assert box.data == <<0, 0, 0, 0, 2::32, 1::32, 4::32>>
  end

  test "build_stsc RLEs per-chunk sample counts" do
    # chunks (1-based) with counts [3, 3, 1] -> entries {1,3} {3,1}
    box = SampleTable.build_stsc([3, 3, 1])
    assert box.data == <<0, 0, 0, 0, 2::32, 1::32, 3::32, 1::32, 3::32, 1::32, 1::32>>
  end
end
