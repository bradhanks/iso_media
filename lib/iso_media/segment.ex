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

  @doc """
  Split `boxes` and write the init + media segments into `dir` (created if absent):
  `init.mp4` and `seg-1.m4s, seg-2.m4s, …`. `opts[:init_name]` overrides the init filename;
  `opts[:segment_pattern]` is a `fn index -> filename end` (default `fn i -> "seg-\#{i}.m4s" end`).
  Returns `{:ok, paths}` (init first, then segments in order) or the first `write/2`
  `{:error, reason}`. Each segment streams disk→disk; the file handle is closed per segment.
  """
  @spec write_segments(Path.t(), [Box.t()], keyword()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def write_segments(dir, boxes, opts \\ []) do
    %{init: init, segments: segments} = split(boxes)
    File.mkdir_p!(dir)

    init_name = Keyword.get(opts, :init_name, "init.mp4")
    pattern = Keyword.get(opts, :segment_pattern, fn i -> "seg-#{i}.m4s" end)
    init_path = Path.join(dir, init_name)

    case ISOMedia.write(init_path, init) do
      :ok -> write_each(segments, dir, pattern, 1, [init_path])
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_each([], _dir, _pattern, _i, acc), do: {:ok, Enum.reverse(acc)}

  defp write_each([seg | rest], dir, pattern, i, acc) do
    path = Path.join(dir, pattern.(i))

    case ISOMedia.write(path, seg) do
      :ok -> write_each(rest, dir, pattern, i + 1, [path | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp styp(%Box{} = ftyp) do
    %Box{ftyp | type: "styp", source_offset: nil, source_size: nil}
  end
end
