defmodule ISOMedia.SampleTest do
  use ExUnit.Case
  alias ISOMedia.Sample

  test "has the expected fields with nil defaults" do
    s = %Sample{}

    assert Map.keys(s) |> Enum.sort() ==
             [:__struct__, :chunk_index, :dts, :index, :offset, :pts, :size, :sync?]
  end

  test "holds sample metadata" do
    s = %Sample{index: 1, chunk_index: 1, dts: 0, pts: 0, size: 10, offset: 1000, sync?: true}
    assert s.index == 1
    assert s.offset == 1000
    assert s.sync?
  end
end
