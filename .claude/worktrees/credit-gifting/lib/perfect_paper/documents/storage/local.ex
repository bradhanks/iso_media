defmodule PerfectPaper.Documents.Storage.Local do
  @moduledoc """
  Local filesystem storage adapter for development and tests.

  Files are written under `System.tmp_dir!/0` so the working tree stays clean
  and parallel test runs remain hermetic.
  """
  @behaviour PerfectPaper.Documents.Storage

  @base_dir Path.join(System.tmp_dir!(), "perfect_paper_uploads")

  @doc "Stores `content` in the local temp directory and returns the generated key."
  @spec store(binary(), keyword()) :: {:ok, %{storage_key: String.t()}} | {:error, term()}
  @impl PerfectPaper.Documents.Storage
  def store(content, _opts \\ []) do
    key = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    File.mkdir_p!(@base_dir)
    File.write!(Path.join(@base_dir, key), content)
    {:ok, %{storage_key: key}}
  end

  @doc "Reads previously stored content by key."
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  @impl PerfectPaper.Documents.Storage
  def read(key) do
    case File.read(Path.join(@base_dir, key)) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end
end
