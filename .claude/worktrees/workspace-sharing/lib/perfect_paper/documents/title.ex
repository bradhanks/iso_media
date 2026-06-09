defmodule PerfectPaper.Documents.Title do
  @moduledoc """
  Pure, best-effort extraction of a manuscript's human-readable title from a
  canonical document.

  Academic uploads rarely store the real title anywhere structured: the file
  name is noise (`HPV_VxHesitant_..._2024.01.05`) and the first heading is
  usually a section label ("TITLE PAGE"). So we look, in order, for:

    1. an explicit `Title: …` line (the convention on most title pages), then
    2. the first heading that isn't a generic front-matter label.

  Returns `nil` when nothing usable is found, so callers can fall back to a
  cleaned file name. This module performs no IO; `PerfectPaper.Documents`
  exposes it via `derive_title/1`.
  """

  # Front-matter / section labels that are never the paper's own title.
  @generic ~w(title page abstract introduction contents acknowledgements
              acknowledgments references bibliography appendix appendices
              methods results discussion conclusion conclusions keywords
              of and the)

  @max_len 300

  @spec derive(map() | nil | term()) :: String.t() | nil
  def derive(%{"content" => content}) when is_list(content) do
    # Title clues live on the title page; only scan the head of the document so
    # a stray "Title:" deep in the body can't hijack the heading.
    nodes = Enum.take(content, 60)
    from_title_line(nodes) || from_first_heading(nodes)
  end

  def derive(_), do: nil

  # A "Title: …" / "Title - …" line anywhere in the scanned head.
  defp from_title_line(nodes) do
    Enum.find_value(nodes, fn node ->
      case Regex.run(~r/^\s*title\s*[:\-—]\s*(.+\S)\s*$/iu, flatten(node)) do
        [_, title] -> clean(title)
        _ -> nil
      end
    end)
  end

  defp from_first_heading(nodes) do
    Enum.find_value(nodes, fn
      %{"type" => "heading"} = node ->
        text = clean(flatten(node))
        if text && not generic?(text), do: text, else: nil

      _ ->
        nil
    end)
  end

  defp generic?(text) do
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\p{L} ]/u, "")
      |> String.split(~r/\s+/u, trim: true)

    words == [] or Enum.all?(words, &(&1 in @generic))
  end

  defp flatten(node), do: node |> collect() |> IO.iodata_to_binary()

  defp collect(%{"text" => t}) when is_binary(t), do: t
  defp collect(%{"content" => content}) when is_list(content), do: Enum.map(content, &collect/1)
  defp collect(list) when is_list(list), do: Enum.map(list, &collect/1)
  defp collect(_), do: ""

  defp clean(nil), do: nil

  defp clean(text) do
    cleaned = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    cond do
      cleaned == "" -> nil
      String.length(cleaned) > @max_len -> nil
      true -> cleaned
    end
  end
end
