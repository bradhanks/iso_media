defmodule PerfectPaper.Documents do
  @moduledoc """
  Document management — uploading, conversion tracking, and content retrieval.

  This is the public API and the only `Repo`/IO boundary for the Documents context.
  All external blob storage goes through the configured `Storage` adapter.
  """
  import Ecto.Query

  alias PerfectPaper.Repo
  alias PerfectPaper.Documents.{Conversion, Document, Notifier, Title}

  # ── Registering uploads ────────────────────────────────────────────────────

  @doc """
  Registers a new document upload for a user, starting in `:pending` status.

  Merges `user_id: user.id` into the provided attrs before inserting.
  """
  @spec register_upload(struct(), map()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def register_upload(user, attrs) do
    attrs = Map.put(Map.new(attrs), :user_id, user.id)
    %Document{} |> Document.register_changeset(attrs) |> Repo.insert()
  end

  # ── Tracking conversion ────────────────────────────────────────────────────

  @doc """
  Marks a document as converted and records its blob storage key.
  """
  @spec mark_converted(Document.t(), String.t()) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t()}
  def mark_converted(%Document{} = document, storage_key) do
    document
    |> Document.convert_changeset(%{storage_key: storage_key})
    |> Repo.update()
  end

  @doc "Notifies the writer that their document's review is ready to read."
  @spec notify_proofreading_complete(struct(), Document.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def notify_proofreading_complete(%{email: email}, %Document{filename: filename}, review_url) do
    Notifier.deliver_proofreading_complete(email, filename, review_url)
  end

  # ── Reading content ────────────────────────────────────────────────────────

  @doc """
  Fetches the raw binary content for a converted document from blob storage.
  """
  @spec read_content(Document.t()) :: {:ok, binary()} | {:error, term()}
  def read_content(%Document{storage_key: key}), do: storage().read(key)

  # ── Appendices ─────────────────────────────────────────────────────────────

  @doc """
  Returns all appendix documents attached to the given parent document.
  """
  @spec list_appendices(Document.t()) :: [Document.t()]
  def list_appendices(%Document{id: parent_id}) do
    from(d in Document, where: d.parent_document_id == ^parent_id)
    |> Repo.all()
  end

  # ── Convenience: store then register ──────────────────────────────────────

  @doc """
  Stores raw binary content via the storage adapter and registers the document
  in a single step, setting status to `:converted` immediately.

  Useful when the upload and conversion are synchronous (e.g., tests, small files).
  """
  @spec store_and_register(struct(), binary(), map()) ::
          {:ok, Document.t()} | {:error, term()}
  def store_and_register(user, content, attrs) do
    with {:ok, %{storage_key: key}} <- storage().store(content, []),
         attrs_with_key <- Map.merge(Map.new(attrs), %{storage_key: key, status: :converted}),
         {:ok, document} <- register_upload(user, attrs_with_key) do
      {:ok, document}
    end
  end

  # ── Ingestion pipeline ────────────────────────────────────────────────────

  @doc """
  Ingests an uploaded manuscript: stores the binary and registers a `:pending`
  document. Does NOT enqueue conversion — the caller enqueues it via
  `start_conversion/1` *after* creating the review session, so the `Conversion`
  worker can never run before the session exists (closes the lost-review race).
  """
  @spec ingest(struct(), binary(), map()) :: {:ok, Document.t()} | {:error, term()}
  def ingest(user, content, attrs) do
    reg =
      attrs
      |> Map.new()
      |> Map.merge(%{status: :pending, byte_size: byte_size(content)})

    with {:ok, %{storage_key: key}} <- storage().store(content, []) do
      register_upload(user, Map.put(reg, :storage_key, key))
    end
  end

  @doc """
  Enqueues background conversion of an ingested document to the canonical SSoT.
  Call this only after any review session for the document has been created, so
  the `Conversion` worker's chained review always finds the session.
  """
  @spec start_conversion(Document.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def start_conversion(%Document{id: id}) do
    %{document_id: id} |> Conversion.new() |> Oban.insert()
  end

  @doc "Fetches a document by id (nil if absent)."
  @spec get_document(binary()) :: Document.t() | nil
  def get_document(id), do: Repo.get(Document, id)

  @doc "Returns the canonical AST map for a document (nil until converted)."
  @spec canonical_doc(Document.t()) :: map() | nil
  def canonical_doc(%Document{canonical_doc: doc}), do: doc

  @doc "The canonical document flattened to plain text (nil until converted)."
  @spec canonical_text(Document.t()) :: String.t() | nil
  def canonical_text(%Document{canonical_doc: nil}), do: nil
  def canonical_text(%Document{canonical_doc: doc}), do: Canonical.flatten_text(doc)

  # ── Titles ───────────────────────────────────────────────────────────────

  @doc """
  Best-effort human title parsed from a canonical document (the "Title:" line
  or first real heading), or `nil` when none can be found. See `Documents.Title`.
  """
  @spec derive_title(map() | nil) :: String.t() | nil
  def derive_title(canonical_doc), do: Title.derive(canonical_doc)

  @doc """
  A readable fallback title built from the upload file name — underscores and
  dashes become spaces, the extension is dropped. Used when no title can be
  parsed from the document.
  """
  @spec humanized_filename(String.t() | nil) :: String.t()
  def humanized_filename(filename) when is_binary(filename) do
    filename
    |> Path.rootname()
    |> String.replace(~r/[_\-]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" -> "Untitled manuscript"
      cleaned -> cleaned
    end
  end

  def humanized_filename(_), do: "Untitled manuscript"

  @doc """
  The best display title for a document: the title parsed from its canonical
  content, falling back to a humanized file name. Never returns nil.
  """
  @spec display_title(Document.t()) :: String.t()
  def display_title(%Document{canonical_doc: doc, filename: filename}),
    do: derive_title(doc) || humanized_filename(filename)

  # ── Export ─────────────────────────────────────────────────────────────────

  # format key → {pandoc output format, extension, content type}
  @export_formats %{
    "markdown" => {:markdown, ".md", "text/markdown; charset=utf-8"},
    "docx" =>
      {:docx, ".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
    "html" => {:html, ".html", "text/html; charset=utf-8"}
  }

  @doc "The export format keys this context can produce."
  @spec export_formats() :: [String.t()]
  def export_formats, do: Map.keys(@export_formats)

  @doc """
  Builds the download file name: the original upload name with a `_PP` suffix
  and the target extension (so the user's file name is preserved, just marked
  as PerfectPaper's output). Falls back to `manuscript_PP<ext>`.
  """
  @spec export_filename(Document.t() | String.t() | nil, String.t()) :: String.t()
  def export_filename(%Document{filename: filename}, ext), do: export_filename(filename, ext)

  def export_filename(filename, ext) when is_binary(filename) and filename != "",
    do: Path.rootname(Path.basename(filename)) <> "_PP" <> ext

  def export_filename(_filename, ext), do: "manuscript_PP" <> ext

  @doc """
  Renders a converted document to a downloadable file in `format` (one of
  `export_formats/0`). Returns `{:ok, %{content, filename, content_type}}`, or
  `{:error, :not_converted | :unsupported_format | term}`.

  Delegates to `Canonical.Export` (Pandoc) for the actual conversion, so the
  exported file round-trips through the same canonical SSoT the review reads.
  """
  @spec export(Document.t(), String.t()) ::
          {:ok, %{content: binary(), filename: String.t(), content_type: String.t()}}
          | {:error, term()}
  def export(%Document{canonical_doc: nil}, _format), do: {:error, :not_converted}

  def export(%Document{canonical_doc: doc, filename: filename}, format) do
    case Map.fetch(@export_formats, format) do
      {:ok, {to, ext, content_type}} ->
        with {:ok, content} <- Canonical.Export.to_format(doc, to: to) do
          {:ok,
           %{
             content: content,
             filename: export_filename(filename, ext),
             content_type: content_type
           }}
        end

      :error ->
        {:error, :unsupported_format}
    end
  end

  @doc """
  Splits a node's flattened text into render-ready highlight segments for the
  active comment anchor. Offsets are UTF-16 code units. Returns a single
  un-highlighted segment when the anchor does not target this node.
  """
  @spec highlight_segments(
          map(),
          %{node_id: String.t(), from: non_neg_integer(), to: non_neg_integer()} | nil
        ) ::
          [%{text: String.t(), highlight: boolean()}]
  def highlight_segments(%{"attrs" => %{"id" => id}} = node, %{node_id: id, from: from, to: to}) do
    full = Canonical.flatten_text(node)
    len = Canonical.utf16_length(full)

    [
      %{text: Canonical.utf16_slice(full, 0, from), highlight: false},
      %{text: Canonical.utf16_slice(full, from, to), highlight: true},
      %{text: Canonical.utf16_slice(full, to, len), highlight: false}
    ]
    |> Enum.reject(&(&1.text == ""))
  end

  def highlight_segments(node, _anchor),
    do: [%{text: Canonical.flatten_text(node), highlight: false}]

  @doc """
  Reverse-maps a text snippet onto a canonical-doc anchor: the deepest block node
  (by `attrs.id`) whose flattened text contains `snippet`, plus the snippet's
  UTF-16 offsets within that node — the exact shape `highlight_segments/2`
  renders against. Returns `nil` when the snippet isn't contained in any single
  node (it spans blocks, isn't present, or there is no canonical doc / snippet).

  Used to anchor AI review comments (which quote `original_text`) back onto the
  document so the workspace can highlight the quoted passage.
  """
  @spec anchor_for_text(Document.t() | map() | nil, String.t() | nil) ::
          %{
            anchor_node_id: String.t(),
            anchor_from: non_neg_integer(),
            anchor_to: non_neg_integer()
          }
          | nil
  def anchor_for_text(%Document{canonical_doc: doc}, snippet), do: anchor_for_text(doc, snippet)
  def anchor_for_text(_doc, snippet) when snippet in [nil, ""], do: nil
  def anchor_for_text(doc, _snippet) when not is_map(doc), do: nil
  def anchor_for_text(doc, snippet), do: find_anchor(doc, snippet)

  # Deepest-first: recurse into children, falling back to this node. Text nodes
  # carry no attrs.id, so the deepest match with an id is the leaf block
  # (paragraph/heading) — the node highlight_segments/2 slices against.
  defp find_anchor(%{"content" => children} = node, snippet) when is_list(children) do
    Enum.find_value(children, &find_anchor(&1, snippet)) || node_anchor(node, snippet)
  end

  defp find_anchor(node, snippet), do: node_anchor(node, snippet)

  defp node_anchor(%{"attrs" => %{"id" => id}} = node, snippet) do
    full = Canonical.flatten_text(node)

    case String.split(full, snippet, parts: 2) do
      [prefix, _rest] ->
        from = Canonical.utf16_length(prefix)

        %{
          anchor_node_id: id,
          anchor_from: from,
          anchor_to: from + Canonical.utf16_length(snippet)
        }

      [_no_match] ->
        nil
    end
  end

  defp node_anchor(_node, _snippet), do: nil

  # ── Private helpers ────────────────────────────────────────────────────────

  defp storage, do: Application.get_env(:perfect_paper, :storage_provider)
end
