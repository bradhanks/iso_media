defmodule PerfectPaper.DocumentsTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.Documents
  alias PerfectPaper.Documents.Document
  alias PerfectPaper.Documents.Storage.Local

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.DocumentsFixtures

  describe "export_filename/2" do
    test "appends _PP to the original name and swaps the extension" do
      assert Documents.export_filename("HPV_Study_2024.01.05.docx", ".md") ==
               "HPV_Study_2024.01.05_PP.md"
    end

    test "falls back to manuscript_PP when there is no file name" do
      assert Documents.export_filename(nil, ".docx") == "manuscript_PP.docx"
      assert Documents.export_filename("", ".docx") == "manuscript_PP.docx"
    end
  end

  describe "export/2" do
    test "errors when the document has not been converted yet" do
      doc = %Document{filename: "x.docx", canonical_doc: nil}
      assert Documents.export(doc, "markdown") == {:error, :not_converted}
    end

    test "rejects an unsupported format" do
      doc = %Document{filename: "x.docx", canonical_doc: %{"type" => "doc", "content" => []}}
      assert Documents.export(doc, "pdf") == {:error, :unsupported_format}
    end

    @tag :pandoc
    test "renders Markdown from the canonical document, named with _PP" do
      doc = %Document{filename: "paper.docx", canonical_doc: export_sample_doc()}
      assert {:ok, file} = Documents.export(doc, "markdown")
      assert file.filename == "paper_PP.md"
      assert file.content_type =~ "text/markdown"
      assert file.content =~ "Vaccine Hesitancy"
    end

    @tag :pandoc
    test "renders a DOCX (zip) binary from the canonical document" do
      doc = %Document{filename: "paper.docx", canonical_doc: export_sample_doc()}
      assert {:ok, file} = Documents.export(doc, "docx")
      assert file.filename == "paper_PP.docx"
      assert <<"PK", _rest::binary>> = file.content
    end
  end

  defp export_sample_doc do
    %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "heading",
          "attrs" => %{"level" => 1},
          "content" => [%{"type" => "text", "text" => "Vaccine Hesitancy"}]
        },
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Body text."}]}
      ]
    }
  end

  describe "register_upload/2 size limit" do
    test "rejects uploads that exceed the 20 MB file size limit" do
      user = user_fixture()

      assert {:error, changeset} =
               Documents.register_upload(user, %{
                 filename: "huge.pdf",
                 byte_size: 21 * 1024 * 1024
               })

      assert %{byte_size: [_]} = errors_on(changeset)
    end

    test "accepts uploads at exactly the 20 MB limit" do
      user = user_fixture()

      assert {:ok, doc} =
               Documents.register_upload(user, %{
                 filename: "max.pdf",
                 byte_size: 20 * 1024 * 1024
               })

      assert doc.byte_size == 20 * 1024 * 1024
    end
  end

  describe "register_upload/2" do
    test "creates a pending document for a user" do
      user = user_fixture()

      assert {:ok, document} =
               Documents.register_upload(user, %{
                 filename: "thesis.pdf",
                 content_type: "application/pdf",
                 byte_size: 42_000
               })

      assert document.status == :pending
      assert document.user_id == user.id
      assert document.filename == "thesis.pdf"
      assert document.content_type == "application/pdf"
      assert document.byte_size == 42_000
    end

    test "requires a filename" do
      user = user_fixture()
      assert {:error, changeset} = Documents.register_upload(user, %{})
      assert %{filename: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error changeset when user_id is missing" do
      # Pass a map directly without a real user to exercise the validation path
      result =
        %PerfectPaper.Documents.Document{}
        |> PerfectPaper.Documents.Document.register_changeset(%{filename: "x.pdf"})

      assert %{user_id: ["can't be blank"]} = errors_on(result)
    end
  end

  describe "mark_converted/2" do
    test "sets status to :converted and persists the storage key" do
      user = user_fixture()
      document = document_fixture(user)

      assert {:ok, converted} = Documents.mark_converted(document, "abc-storage-key")
      assert converted.status == :converted
      assert converted.storage_key == "abc-storage-key"
    end
  end

  describe "list_appendices/1" do
    test "returns child documents for a parent" do
      user = user_fixture()
      parent = document_fixture(user, %{filename: "main.pdf"})

      {:ok, appendix} =
        Documents.register_upload(user, %{
          filename: "appendix_a.pdf",
          parent_document_id: parent.id
        })

      appendices = Documents.list_appendices(parent)
      assert length(appendices) == 1
      assert hd(appendices).id == appendix.id
    end

    test "returns an empty list when there are no appendices" do
      user = user_fixture()
      parent = document_fixture(user)
      assert Documents.list_appendices(parent) == []
    end
  end

  describe "Storage.Local round-trip" do
    test "store/2 then read/1 returns the same binary" do
      content = :crypto.strong_rand_bytes(64)

      assert {:ok, %{storage_key: key}} = Local.store(content)
      assert {:ok, ^content} = Local.read(key)
    end

    test "read/1 returns {:error, :enoent} for a missing key" do
      assert {:error, :enoent} = Local.read("does-not-exist-#{System.unique_integer()}")
    end
  end

  describe "canonical_changeset/2" do
    test "accepts a valid canonical doc and sets :converted" do
      user = user_fixture()
      doc = document_fixture(user)

      tree = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "id" => "n_1",
            "content" => [%{"type" => "text", "text" => "Hi"}]
          }
        ]
      }

      changeset =
        PerfectPaper.Documents.Document.canonical_changeset(doc, %{
          canonical_doc: tree,
          canonical_meta: %{"title" => "T"},
          source_format: "markdown",
          status: :converted
        })

      assert changeset.valid?
      assert {:ok, saved} = PerfectPaper.Repo.update(changeset)
      assert saved.status == :converted
      assert saved.canonical_doc["content"] |> hd() |> Map.get("id") == "n_1"
    end

    test "rejects a malformed canonical doc" do
      user = user_fixture()
      doc = document_fixture(user)

      # panpipe's schema validator rejects unknown node types. (Stable ids are
      # minted at import time, so the schema does not require them at validation.)
      bad = %{"type" => "totally_unknown_node"}

      changeset =
        PerfectPaper.Documents.Document.canonical_changeset(doc, %{
          canonical_doc: bad,
          status: :converted
        })

      refute changeset.valid?
      assert %{canonical_doc: [msg]} = errors_on(changeset)
      assert msg =~ "unknown node type"
    end
  end

  describe "ingest/3" do
    test "stores the binary and registers a pending document WITHOUT enqueuing conversion" do
      user = user_fixture()

      assert {:ok, document} =
               Documents.ingest(user, "# Hello\n", %{filename: "h.md", source_format: "markdown"})

      assert document.status == :pending
      assert document.byte_size == byte_size("# Hello\n")
      assert {:ok, _content} = Documents.read_content(document)

      # Conversion is NOT enqueued here — the caller enqueues it via
      # start_conversion/1 *after* creating the session, so the Conversion worker
      # can never run before the session exists (closes the lost-review race).
      refute_enqueued(worker: PerfectPaper.Documents.Conversion)
    end
  end

  describe "start_conversion/1" do
    test "enqueues the Conversion worker for the document" do
      user = user_fixture()

      {:ok, document} =
        Documents.ingest(user, "# Hi\n", %{filename: "h.md", source_format: "markdown"})

      assert {:ok, _job} = Documents.start_conversion(document)

      assert_enqueued(
        worker: PerfectPaper.Documents.Conversion,
        args: %{"document_id" => document.id}
      )
    end
  end

  describe "canonical_text/1" do
    test "flattens the canonical doc to plain text; nil when unconverted" do
      user = user_fixture()
      doc = document_fixture(user)
      assert Documents.canonical_text(doc) == nil

      tree = %{
        "type" => "doc",
        "content" => [
          %{
            "type" => "paragraph",
            "id" => "n_1",
            "content" => [%{"type" => "text", "text" => "Hello world"}]
          }
        ]
      }

      {:ok, converted} =
        doc
        |> PerfectPaper.Documents.Document.canonical_changeset(%{
          canonical_doc: tree,
          status: :converted
        })
        |> PerfectPaper.Repo.update()

      assert Documents.canonical_text(converted) == "Hello world"
    end
  end

  describe "highlight_segments/2" do
    @hseg_node %{
      "type" => "paragraph",
      "attrs" => %{"id" => "n_x"},
      "content" => [%{"type" => "text", "text" => "hello world"}]
    }

    test "returns one un-highlighted segment when no anchor matches" do
      assert [%{text: "hello world", highlight: false}] =
               Documents.highlight_segments(@hseg_node, nil)
    end

    test "splits the node text at the UTF-16 range for a matching anchor" do
      segs = Documents.highlight_segments(@hseg_node, %{node_id: "n_x", from: 0, to: 5})
      assert segs == [%{text: "hello", highlight: true}, %{text: " world", highlight: false}]
    end
  end

  describe "anchor_for_text/2" do
    @anchor_doc %{
      "type" => "doc",
      "content" => [
        %{
          "type" => "paragraph",
          "attrs" => %{"id" => "p1"},
          "content" => [%{"type" => "text", "text" => "The quick brown fox jumps."}]
        },
        %{
          "type" => "blockquote",
          "attrs" => %{"id" => "bq"},
          "content" => [
            %{
              "type" => "paragraph",
              "attrs" => %{"id" => "p2"},
              "content" => [%{"type" => "text", "text" => "Nested cœur résumé passage."}]
            }
          ]
        }
      ]
    }

    test "maps a snippet to its block node with UTF-16 offsets matching highlight_segments" do
      assert Documents.anchor_for_text(@anchor_doc, "quick brown") ==
               %{anchor_node_id: "p1", anchor_from: 4, anchor_to: 15}
    end

    test "targets the deepest (leaf) node, not its container" do
      assert %{anchor_node_id: "p2"} = Documents.anchor_for_text(@anchor_doc, "résumé")
    end

    test "returns nil when the snippet is absent or spans nodes" do
      assert Documents.anchor_for_text(@anchor_doc, "not in the document") == nil
      assert Documents.anchor_for_text(@anchor_doc, "jumps. Nested") == nil
    end

    test "returns nil for empty/nil snippet or no canonical doc" do
      assert Documents.anchor_for_text(@anchor_doc, nil) == nil
      assert Documents.anchor_for_text(@anchor_doc, "") == nil
      assert Documents.anchor_for_text(nil, "x") == nil
      assert Documents.anchor_for_text(%Document{canonical_doc: nil}, "x") == nil
    end

    test "accepts a Document struct" do
      assert %{anchor_node_id: "p1"} =
               Documents.anchor_for_text(%Document{canonical_doc: @anchor_doc}, "fox")
    end
  end

  describe "display_title/1 + humanized_filename/1" do
    test "prefers the title derived from the canonical doc" do
      doc = %Document{
        filename: "HPV_Study_2024.01.05.docx",
        canonical_doc: %{
          "type" => "doc",
          "content" => [
            %{
              "type" => "heading",
              "attrs" => %{"id" => "h1", "level" => 1},
              "content" => [%{"type" => "text", "text" => "Vaccine Hesitancy in Rural Clinics"}]
            }
          ]
        }
      }

      assert Documents.display_title(doc) == "Vaccine Hesitancy in Rural Clinics"
    end

    test "falls back to a humanized file name when no title can be derived" do
      doc = %Document{filename: "my_manuscript_v2-final.docx", canonical_doc: nil}
      assert Documents.display_title(doc) == "my manuscript v2 final"
    end

    test "humanized_filename never returns nil" do
      assert Documents.humanized_filename(nil) == "Untitled manuscript"
      assert Documents.humanized_filename(".docx") == "Untitled manuscript"
    end
  end
end
