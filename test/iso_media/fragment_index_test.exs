defmodule ISOMedia.FragmentIndexTest do
  use ExUnit.Case
  alias ISOMedia.{Box, FragmentIndex}

  defp moov(children), do: %Box{type: "moov", children: children}
  defp leaf(type, data), do: %Box{type: type, data: data}

  test "fragmented?/1 is true only with both mvex and moof" do
    mvex = %Box{type: "mvex", children: [leaf("trex", <<0::32, 1::32, 1::32, 0::32, 0::32, 0::32>>)]}
    moof = %Box{type: "moof", children: []}

    assert FragmentIndex.fragmented?([moov([mvex]), moof]) == true
    assert FragmentIndex.fragmented?([moov([mvex])]) == false
    assert FragmentIndex.fragmented?([moov([]), moof]) == false
    assert FragmentIndex.fragmented?([moov([])]) == false
  end

  test "samples/2 still routes a progressive file to SampleTable" do
    {:ok, boxes} = ISOMedia.read("test/fixtures/sample_av.mp4")
    [tid | _] = ISOMedia.track_ids(boxes)
    assert is_list(ISOMedia.samples(boxes, tid))
    assert FragmentIndex.fragmented?(boxes) == false
  end
end
