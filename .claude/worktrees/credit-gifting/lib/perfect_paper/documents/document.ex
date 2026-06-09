defmodule PerfectPaper.Documents.Document do
  @moduledoc """
  A document uploaded by a writer for proofreading.

  Tracks the upload lifecycle from pending through conversion, stores the
  blob storage key, and supports self-referential appendix attachments.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses [:pending, :converting, :converted, :failed]
  @max_upload_bytes 20 * 1024 * 1024

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "documents" do
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :storage_key, :string
    field :canonical_doc, :map
    field :canonical_meta, :map
    field :source_format, :string
    field :user_id, :binary_id

    belongs_to :parent_document, __MODULE__
    has_many :appendices, __MODULE__, foreign_key: :parent_document_id

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset to register a new uploaded document."
  @spec register_changeset(t(), map()) :: Ecto.Changeset.t()
  def register_changeset(document, attrs) do
    document
    |> cast(attrs, [
      :filename,
      :content_type,
      :byte_size,
      :user_id,
      :parent_document_id,
      :storage_key,
      :status,
      :source_format
    ])
    |> validate_required([:filename, :user_id])
    |> validate_number(:byte_size,
      less_than_or_equal_to: @max_upload_bytes,
      message: "must be 20 MB or less"
    )
  end

  @doc "Marks a document as converted and records its storage key."
  @spec convert_changeset(t(), map()) :: Ecto.Changeset.t()
  def convert_changeset(document, attrs) do
    document
    |> cast(attrs, [:storage_key])
    |> put_change(:status, :converted)
  end

  @doc "Persists the converted canonical AST; validates it via the panpipe Canonical library."
  @spec canonical_changeset(t(), map()) :: Ecto.Changeset.t()
  def canonical_changeset(document, attrs) do
    document
    |> cast(attrs, [:canonical_doc, :canonical_meta, :source_format, :status])
    |> validate_change(:canonical_doc, fn :canonical_doc, doc ->
      case Canonical.validate(doc) do
        :ok ->
          []

        {:error, violations} ->
          first = hd(violations)
          [canonical_doc: "[at #{first.path}] #{first.message}"]
      end
    end)
  end

  @doc "Sets only the processing status (used by the conversion worker)."
  @spec status_changeset(t(), atom()) :: Ecto.Changeset.t()
  def status_changeset(document, status), do: change(document, status: status)
end
