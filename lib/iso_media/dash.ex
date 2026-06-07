defmodule ISOMedia.DASH do
  @moduledoc """
  Generate the DASH MPD (`.mpd`) for the CMAF segments `ISOMedia.split_segments/1` produces:
  a single muxed `static`/VOD rendition using `SegmentTemplate` + `SegmentTimeline`. Pure XML
  templating over `FragmentIndex.fragment_spans/1` + `ISOMedia.Manifest` (the same
  codec/resolution/bandwidth computations HLS uses), via a small zero-dependency XML builder
  (`element/3` + `attr_escape/1` + `iso8601_duration/1`) — the library keeps no runtime deps,
  and the MPD's value surface is small and controlled. `write_dash/3` derives the segment
  filenames from the `$Number$` template so the written files match the manifest.
  """
  alias ISOMedia.{FragmentIndex, Manifest}

  @mpd_ns "urn:mpeg:dash:schema:mpd:2011"
  @profile "urn:mpeg:dash:profile:isoff-live:2011"

  @doc """
  The DASH MPD (`.mpd`) string for a fragmented tree.

  `opts`: `:init_name` (`"init.mp4"`), `:segment_template` (`"seg-$Number$.m4s"`).
  Raises `ArgumentError` on a non-fragmented (progressive) tree.
  """
  @spec manifest([ISOMedia.Box.t()], keyword()) :: String.t()
  def manifest(boxes, opts \\ []) do
    validate!(boxes)
    init_name = Keyword.get(opts, :init_name, "init.mp4")
    template = Keyword.get(opts, :segment_template, "seg-$Number$.m4s")

    spans = FragmentIndex.fragment_spans(boxes)
    timescale = hd(spans).timescale
    total_ts = spans |> Enum.map(& &1.duration_ts) |> Enum.sum()

    {content_type, mime, dims} =
      case Manifest.video_dimensions(boxes) do
        nil -> {"audio", "audio/mp4", []}
        {w, h} -> {"video", "video/mp4", [width: w, height: h]}
      end

    rep_attrs =
      [id: 1, codecs: Manifest.codecs(boxes), bandwidth: Manifest.peak_bandwidth(boxes)] ++ dims

    timeline = Enum.map(spans, fn s -> {"S", [d: s.duration_ts], []} end)

    tree =
      {"MPD",
       [
         xmlns: @mpd_ns,
         profiles: @profile,
         type: "static",
         minBufferTime: "PT1.5S",
         mediaPresentationDuration: iso8601_duration(total_ts / timescale)
       ],
       [
         {"Period", [],
          [
            {"AdaptationSet",
             [
               contentType: content_type,
               mimeType: mime,
               segmentAlignment: "true",
               startWithSAP: "1"
             ],
             [
               {"Representation", rep_attrs,
                [
                  {"SegmentTemplate",
                   [
                     timescale: timescale,
                     initialization: init_name,
                     media: template,
                     startNumber: 1
                   ], [{"SegmentTimeline", [], timeline}]}
                ]}
             ]}
          ]}
       ]}

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      "\n" <> Enum.join(element(tree, 0), "\n") <> "\n"
  end

  @doc """
  Write the DASH bundle into `dir` (created if absent): the MPD (`opts[:manifest_name]`,
  default `manifest.mpd`) and — via `ISOMedia.write_segments/3` — `init.mp4` + the media
  segments. The `write_segments` `:segment_pattern` is derived from `:segment_template` so the
  written filenames match the manifest. Returns `{:ok, [manifest_path | segment_paths]}`.
  """
  @spec write_dash(Path.t(), [ISOMedia.Box.t()], keyword()) :: {:ok, [Path.t()]}
  def write_dash(dir, boxes, opts \\ []) do
    File.mkdir_p!(dir)
    template = Keyword.get(opts, :segment_template, "seg-$Number$.m4s")
    manifest_path = Path.join(dir, Keyword.get(opts, :manifest_name, "manifest.mpd"))

    File.write!(manifest_path, manifest(boxes, opts))

    seg_opts =
      opts
      |> Keyword.put_new(:init_name, "init.mp4")
      |> Keyword.put(:segment_pattern, fn i ->
        String.replace(template, "$Number$", Integer.to_string(i))
      end)

    {:ok, segment_paths} = ISOMedia.write_segments(dir, boxes, seg_opts)
    {:ok, [manifest_path | segment_paths]}
  end

  @doc """
  Escape an XML attribute value: `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`
  (ampersand first so existing entities are not double-escaped).
  """
  @spec attr_escape(String.t()) :: String.t()
  def attr_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Render an `{name, attrs, children}` element to a list of 2-space-indented lines at `depth`.
  # Empty children → a self-closing tag; otherwise an open/close pair wrapping the children.
  defp element({name, attrs, children}, depth) do
    pad = String.duplicate("  ", depth)
    open = "#{pad}<#{name}#{render_attrs(attrs)}"

    case children do
      [] ->
        [open <> "/>"]

      _ ->
        [open <> ">"] ++
          Enum.flat_map(children, &element(&1, depth + 1)) ++
          ["#{pad}</#{name}>"]
    end
  end

  defp render_attrs(attrs) do
    Enum.map_join(attrs, "", fn {k, v} -> ~s( #{k}="#{attr_escape(to_string(v))}") end)
  end

  # Total seconds → ISO-8601 duration with 3 decimals, e.g. 2.0 → "PT2.000S".
  defp iso8601_duration(seconds) do
    "PT" <> :erlang.float_to_binary(seconds, decimals: 3) <> "S"
  end

  defp validate!(boxes) do
    unless FragmentIndex.fragmented?(boxes) do
      raise ArgumentError, "dash: expected a fragmented (fragment/2) tree"
    end
  end
end
