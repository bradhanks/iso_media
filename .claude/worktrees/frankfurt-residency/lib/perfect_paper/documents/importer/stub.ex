defmodule PerfectPaper.Documents.Importer.Stub do
  @moduledoc "Deterministic importer for tests — returns a fixed, valid canonical doc."
  @behaviour PerfectPaper.Documents.Importer

  @impl true
  def import(_content, _opts) do
    {:ok,
     %{
       doc: %{
         "type" => "doc",
         "content" => [
           %{
             "type" => "heading",
             "id" => "n_stub_h",
             "attrs" => %{"level" => 1},
             "content" => [%{"type" => "text", "text" => "Stub Title"}]
           },
           %{
             "type" => "paragraph",
             "id" => "n_stub_p",
             "content" => [%{"type" => "text", "text" => "Stub body paragraph."}]
           }
         ]
       },
       meta: %{"title" => "Stub Title", "word_count" => 3, "source_format" => "stub"}
     }}
  end
end
