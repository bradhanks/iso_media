defmodule PerfectPaper.DocumentsFixtures do
  @moduledoc "Test fixtures for the Documents context."

  alias PerfectPaper.Documents

  @doc """
  Creates a pending document for `user` with optional attribute overrides.

      document_fixture(user)
      document_fixture(user, %{filename: "appendix.pdf"})
  """
  def document_fixture(user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{filename: "paper_#{System.unique_integer()}.pdf"},
        Map.new(attrs)
      )

    {:ok, document} = Documents.register_upload(user, attrs)
    document
  end
end
