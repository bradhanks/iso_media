defmodule ISOMedia.Segment do
  @moduledoc """
  Split a fragmented MP4 tree (the output of `ISOMedia.fragment/2`, shape
  `[ftyp, moov, (moof, mdat)+]`) into the DASH/CMAF on-disk layout: a media-less init
  segment (`[ftyp, moov]`) plus N standalone media segments (`[styp, moof, mdat]`).

  Lossless and memory-safe — each segment's `mdat` stays a source-referencing segment
  list, so `write_segments/3` streams each segment file disk→disk. The split is
  structure-preserving: a muxed input yields muxed segments. For single-track segments,
  compose `extract_track |> fragment |> split` per track.
  """
  alias ISOMedia.Box

  @doc """
  Split a fragmented tree into `%{init: [ftyp, moov], segments: [[styp, moof, mdat], …]}`.
  Raises `ArgumentError` unless the input is `[ftyp, moov, (moof, mdat)+]`.
  """
  @spec split([Box.t()]) :: %{init: [Box.t()], segments: [[Box.t()]]}
  def split([%Box{type: "ftyp"} = ftyp, %Box{type: "moov"} = moov | rest]) do
    %{init: [ftyp, moov], segments: pair_fragments(rest, styp(ftyp), [])}
  end

  def split(_boxes) do
    raise ArgumentError, "split_segments: expected a fragmented tree [ftyp, moov, (moof, mdat)+]"
  end

  defp pair_fragments([], _styp, []) do
    raise ArgumentError, "split_segments: no moof/mdat fragments (input is not fragmented)"
  end

  defp pair_fragments([], _styp, acc), do: Enum.reverse(acc)

  defp pair_fragments([%Box{type: "moof"} = moof, %Box{type: "mdat"} = mdat | rest], styp, acc) do
    pair_fragments(rest, styp, [[styp, moof, mdat] | acc])
  end

  defp pair_fragments([%Box{type: "moof"} | _], _styp, _acc) do
    raise ArgumentError, "split_segments: a moof is not followed by an mdat"
  end

  defp pair_fragments([%Box{type: t} | _], _styp, _acc) do
    raise ArgumentError, "split_segments: expected moof/mdat fragments, got #{t}"
  end

  defp styp(%Box{} = ftyp) do
    %Box{ftyp | type: "styp", source_offset: nil, source_size: nil}
  end
end
