# docx Upload Wiring (Piece A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make uploading a `.docx` at `/new` flow through the canonical ingestion pipeline and render in the workspace, with the AI review chained asynchronously after conversion.

**Architecture:** `/new` → best-effort credit pre-check → `Documents.ingest/3` (async `Conversion`) → `History.begin_session(document_id)` → redirect. The `Conversion` worker, on success, broadcasts to a document-scoped PubSub topic (`"document:#{id}"`) and enqueues an idempotent review job; `WorkspaceLive` subscribes to that topic and renders converting/ready/failed states.

**Tech Stack:** Phoenix LiveView, Ecto, Oban 2.23 (incl. `unique`), Phoenix.PubSub.

**Spec:** `docs/superpowers/specs/2026-06-04-docx-upload-wiring-design.md`. docx-only; PDF + anchored comments out of scope.

**Branch:** Continue on the existing `feat/docx-upload-wiring` (already checked out; the two spec docs are already committed there). Do NOT branch or merge until Task 7.

---

## File Structure

**New**
- `lib/perfect_paper/history/review_worker.ex` — thin Oban worker (queue `:reviews`, `unique` on `session_id`) that runs `process_session` on canonical text.
- `test/perfect_paper/history/review_worker_test.exs`

**Modified**
- `config/config.exs` — add `reviews:` Oban queue.
- `lib/perfect_paper/history.ex` — expose `intended_level/1`; add `sessions_for_document/1` + `enqueue_review/1`.
- `lib/perfect_paper/documents.ex` — add `canonical_text/1`.
- `lib/perfect_paper/documents/conversion.ex` — scoped broadcast + chain review on success/failure.
- `lib/perfect_paper_web/live/new_live.ex` (+ `new_live.html.heex`) — docx-only, ingest wiring, title-from-filename, `phx-disable-with`.
- `lib/perfect_paper_web/live/workspace_live.ex` — scoped subscribe + converting/ready/failed states.
- Tests alongside each.

---

## Task 1: Oban `:reviews` queue

**Files:** Modify `config/config.exs:113`

- [ ] **Step 1: Add the queue**

Change the Oban `queues:` line:

```elixir
  queues: [webhooks: 10, documents: 10, reviews: 10],
```

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add config/config.exs
git commit -m "chore(history): add :reviews Oban queue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: History/Documents context helpers

**Files:**
- Modify: `lib/perfect_paper/history.ex`
- Modify: `lib/perfect_paper/documents.ex`
- Test: `test/perfect_paper/history_test.exs` (append), `test/perfect_paper/documents_test.exs` (append)

Context: `History.intended_level/1` currently exists as a **private** function:
```elixir
defp intended_level(user_id) do
  cond do
    Credits.balance(user_id, :paid) >= 1 -> {:ok, :full}
    Credits.balance(user_id, :preview) >= 1 -> {:ok, :preview}
    true -> {:error, :no_credits}
  end
end
```
`Documents.Canonical.flatten_text/1` and `Documents.canonical_doc/1` exist.

- [ ] **Step 1: Write failing tests**

Append to `test/perfect_paper/history_test.exs`:

```elixir
  describe "intended_level/1 + sessions_for_document/1" do
    test "intended_level reflects credit balance" do
      user = user_fixture()
      assert PerfectPaper.History.intended_level(user.id) == {:error, :no_credits}
      PerfectPaper.Credits.grant(user.id, 1, "test")
      assert PerfectPaper.History.intended_level(user.id) == {:ok, :full}
    end

    test "sessions_for_document returns sessions linked to a document" do
      user = user_fixture()
      {:ok, document} = PerfectPaper.Documents.register_upload(user, %{filename: "m.docx"})

      {:ok, session} =
        PerfectPaper.History.begin_session(%{user_id: user.id, title: "M", document_id: document.id})

      ids = PerfectPaper.History.sessions_for_document(document.id) |> Enum.map(& &1.id)
      assert session.id in ids
    end
  end
```

Append to `test/perfect_paper/documents_test.exs`:

```elixir
  describe "canonical_text/1" do
    test "flattens the canonical doc to plain text; nil when unconverted" do
      user = user_fixture()
      doc = document_fixture(user)
      assert Documents.canonical_text(doc) == nil

      tree = %{"type" => "doc", "content" => [
        %{"type" => "paragraph", "id" => "n_1", "content" => [%{"type" => "text", "text" => "Hello world"}]}
      ]}
      {:ok, converted} =
        doc |> PerfectPaper.Documents.Document.canonical_changeset(%{canonical_doc: tree, status: :converted})
        |> PerfectPaper.Repo.update()

      assert Documents.canonical_text(converted) == "Hello world"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/perfect_paper/history_test.exs test/perfect_paper/documents_test.exs`
Expected: FAIL (`intended_level/1`/`sessions_for_document/1`/`canonical_text/1` undefined or private).

- [ ] **Step 3: Implement**

In `lib/perfect_paper/history.ex`: change `defp intended_level(user_id) do` to a public function with docs:

```elixir
  @doc "Best-effort entitlement: the review level the user can afford right now."
  @spec intended_level(Ecto.UUID.t()) :: {:ok, :full | :preview} | {:error, :no_credits}
  def intended_level(user_id) do
    cond do
      Credits.balance(user_id, :paid) >= 1 -> {:ok, :full}
      Credits.balance(user_id, :preview) >= 1 -> {:ok, :preview}
      true -> {:error, :no_credits}
    end
  end
```

Add (near the other queries; `Session` and `Repo` and `import Ecto.Query` are already in scope):

```elixir
  @doc "All sessions whose source document is `document_id`."
  @spec sessions_for_document(Ecto.UUID.t()) :: [Session.t()]
  def sessions_for_document(document_id) do
    from(s in Session, where: s.document_id == ^document_id) |> Repo.all()
  end

  @doc "Enqueues an idempotent async review for a session (see History.ReviewWorker)."
  @spec enqueue_review(Session.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_review(%Session{id: id}) do
    %{session_id: id} |> PerfectPaper.History.ReviewWorker.new() |> Oban.insert()
  end
```

In `lib/perfect_paper/documents.ex` add:

```elixir
  @doc "The canonical document flattened to plain text (nil until converted)."
  @spec canonical_text(Document.t()) :: String.t() | nil
  def canonical_text(%Document{canonical_doc: nil}), do: nil
  def canonical_text(%Document{canonical_doc: doc}), do: Canonical.flatten_text(doc)
```

(`Canonical` is already aliased in `documents.ex`.) Note: `enqueue_review/1` references `History.ReviewWorker`, created in Task 3 — Elixir compiles fine with a forward module reference; the worker just must exist before `enqueue_review` is *called* (Task 4 / tests).

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/perfect_paper/history_test.exs test/perfect_paper/documents_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/history.ex lib/perfect_paper/documents.ex test/perfect_paper/history_test.exs test/perfect_paper/documents_test.exs
git commit -m "feat(history): public intended_level/1, sessions_for_document/1, enqueue_review/1; Documents.canonical_text/1

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `History.ReviewWorker` (idempotent)

**Files:**
- Create: `lib/perfect_paper/history/review_worker.ex`
- Test: `test/perfect_paper/history/review_worker_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule PerfectPaper.History.ReviewWorkerTest do
  use PerfectPaper.DataCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  alias PerfectPaper.{Credits, Documents, History, Repo}
  alias PerfectPaper.Documents.Document
  alias PerfectPaper.History.{ReviewWorker, Session}

  import PerfectPaper.AccountsFixtures

  defp converted_doc_and_session(user) do
    {:ok, doc} = Documents.store_and_register(user, "bytes", %{filename: "p.docx", source_format: "docx"})

    tree = %{"type" => "doc", "content" => [
      %{"type" => "paragraph", "id" => "n_1", "content" => [%{"type" => "text", "text" => "The manuscript body."}]}
    ]}

    {:ok, doc} =
      doc |> Document.canonical_changeset(%{canonical_doc: tree, status: :converted}) |> Repo.update()

    {:ok, session} = History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})
    {doc, session}
  end

  test "runs the review on canonical text and completes the session" do
    user = user_fixture()
    Credits.grant(user.id, 1, "test")
    {_doc, session} = converted_doc_and_session(user)

    assert :ok = perform_job(ReviewWorker, %{"session_id" => session.id})

    reloaded = Repo.get!(Session, session.id) |> Repo.preload(:comments)
    assert reloaded.processing_status == :complete
    assert length(reloaded.comments) > 0
  end

  test "is unique per session — a duplicate enqueue is deduped" do
    user = user_fixture()
    {_doc, session} = converted_doc_and_session(user)

    assert {:ok, _} = History.enqueue_review(session)
    assert {:ok, _} = History.enqueue_review(session)
    assert_enqueued(worker: ReviewWorker, args: %{"session_id" => session.id})
    assert length(all_enqueued(worker: ReviewWorker)) == 1
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper/history/review_worker_test.exs`
Expected: FAIL — `ReviewWorker` undefined.

- [ ] **Step 3: Implement the worker**

```elixir
defmodule PerfectPaper.History.ReviewWorker do
  @moduledoc """
  Runs the AI review for a session, async, on the canonical document text.
  Chained after document conversion. Idempotent: `unique` on `session_id` so a
  Conversion retry can't enqueue a duplicate (which would mean duplicate paid
  LLM calls).
  """
  use Oban.Worker,
    queue: :reviews,
    unique: [keys: [:session_id], states: ~w(available scheduled executing retryable)a]

  alias PerfectPaper.{Documents, History, Repo}
  alias PerfectPaper.History.Session

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    session = Repo.get!(Session, session_id)

    with %Session{document_id: doc_id} when not is_nil(doc_id) <- session,
         %Documents.Document{} = document <- Documents.get_document(doc_id),
         text when is_binary(text) <- Documents.canonical_text(document),
         {:ok, _reviewed} <- History.process_session(session, text) do
      :ok
    else
      nil -> {:cancel, :document_missing}
      %Session{document_id: nil} -> {:cancel, :no_document}
      text when is_nil(text) -> {:cancel, :not_converted}
      {:error, :no_credits} -> {:cancel, :no_credits}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper/history/review_worker_test.exs`
Expected: PASS (2 tests). The review uses the Stub LLM in test, so it returns canned comments.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/history/review_worker.ex test/perfect_paper/history/review_worker_test.exs
git commit -m "feat(history): ReviewWorker — async, idempotent review on canonical text

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Conversion worker — scoped broadcast + chain review

**Files:**
- Modify: `lib/perfect_paper/documents/conversion.ex`
- Test: `test/perfect_paper/documents/conversion_test.exs` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/perfect_paper/documents/conversion_test.exs` (it already has `use Oban.Testing`, `import AccountsFixtures`, and a `pending_doc/1` helper that stores+registers then resets to `:pending`):

```elixir
  describe "chaining + scoped broadcast" do
    test "on success: broadcasts to document:<id> and enqueues a review for the linked session" do
      user = user_fixture()
      doc = pending_doc(user)

      {:ok, session} =
        PerfectPaper.History.begin_session(%{user_id: user.id, title: "P", document_id: doc.id})

      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{doc.id}")

      assert :ok = perform_job(Conversion, %{"document_id" => doc.id})

      assert_received {:document_converted, id} when id == doc.id
      assert_enqueued(worker: PerfectPaper.History.ReviewWorker, args: %{"session_id" => session.id})
    end

    test "on deterministic failure: broadcasts conversion_failed to document:<id>" do
      user = user_fixture()
      {:ok, doc} =
        PerfectPaper.Documents.register_upload(user, %{
          filename: "p.docx", source_format: "docx",
          storage_key: "missing-#{System.unique_integer([:positive])}"
        })

      Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{doc.id}")
      assert {:cancel, _} = perform_job(Conversion, %{"document_id" => doc.id})
      assert_received {:document_conversion_failed, id} when id == doc.id
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper/documents/conversion_test.exs`
Expected: FAIL (no broadcast received / no review enqueued).

- [ ] **Step 3: Implement — edit the success and failure branches of `perform/1`**

Replace the success branch body:

```elixir
      Events.emit(:"document.converted", %{resource: %{"document_id" => converted.id}})
      :ok
```

with:

```elixir
      Events.emit(:"document.converted", %{resource: %{"document_id" => converted.id}})
      broadcast(converted.id, {:document_converted, converted.id})
      Enum.each(History.sessions_for_document(converted.id), &History.enqueue_review/1)
      :ok
```

In the failure branch, after the `Events.emit(:"document.conversion_failed", ...)` call and before the `if deterministic?...`, add:

```elixir
        broadcast(document.id, {:document_conversion_failed, document.id})
```

Add the alias and helper:

```elixir
  alias PerfectPaper.{Documents, Events, History, Repo}   # add History to the existing alias line
```

```elixir
  defp broadcast(document_id, message),
    do: Phoenix.PubSub.broadcast(PerfectPaper.PubSub, "document:#{document_id}", message)
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper/documents/conversion_test.exs`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper/documents/conversion.ex test/perfect_paper/documents/conversion_test.exs
git commit -m "feat(documents): Conversion broadcasts scoped status + chains idempotent review

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: NewLive — docx-only + ingest wiring

**Files:**
- Modify: `lib/perfect_paper_web/live/new_live.ex`, `lib/perfect_paper_web/live/new_live.html.heex`
- Test: `test/perfect_paper_web/live/new_live_test.exs` (create if absent)

Context — current `submit` (to be replaced):
```elixir
with {:ok, _document} <- Documents.store_and_register(user, content, attrs),
     {:ok, session} <- History.begin_session(%{user_id: user.id, title: entry.client_name}) do
  History.process_session(session, content)
end
```

- [ ] **Step 1: Write the failing test**

Read `new_live.html.heex` first to get the form id and submit/upload selectors; adapt the selectors below to match. Create `test/perfect_paper_web/live/new_live_test.exs`:

```elixir
defmodule PerfectPaperWeb.NewLiveTest do
  use PerfectPaperWeb.ConnCase, async: true
  use Oban.Testing, repo: PerfectPaper.Repo

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.{Credits, Repo}
  alias PerfectPaper.Documents.Document

  @docx_type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  test "uploading a .docx ingests a pending doc, links a session, enqueues conversion, redirects",
       %{conn: conn} do
    user = user_fixture()
    Credits.grant(user.id, 1, "test")
    conn = log_in_user(conn, user)

    {:ok, lv, _html} = live(conn, ~p"/new")

    file =
      file_input(lv, "#manuscript-form", :manuscript, [
        %{name: "My Paper.docx", content: "fake-docx-bytes", type: @docx_type}
      ])

    render_upload(file, "My Paper.docx")

    render_submit(form(lv, "#manuscript-form"))
    assert_redirect(lv, ~p"/workspace/#{redirected_session_id()}") || :ok

    doc = Repo.get_by!(Document, filename: "My Paper.docx")
    assert doc.status == :pending
    assert doc.source_format == "docx"
    assert_enqueued(worker: PerfectPaper.Documents.Conversion, args: %{"document_id" => doc.id})
  end

  test "out of credits: shows the message and ingests nothing", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/new")

    file =
      file_input(lv, "#manuscript-form", :manuscript, [
        %{name: "p.docx", content: "x", type: @docx_type}
      ])

    render_upload(file, "p.docx")
    html = render_submit(form(lv, "#manuscript-form"))

    assert html =~ "out of credits"
    assert PerfectPaper.Repo.aggregate(Document, :count) == 0
  end
end
```

> The redirect assertion is approximate — use whatever `assert_redirect(lv)` returns (it gives the path); assert it matches `~p"/workspace/" <> _`. The contract is: a `.docx` upload creates a `:pending` document, links a session, enqueues `Conversion`, and redirects to the workspace; out-of-credits ingests nothing and shows the message. Adapt selectors (`#manuscript-form`) to the real template. (Drop the `redirected_session_id()` placeholder line — assert the redirect path prefix instead.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/live/new_live_test.exs`
Expected: FAIL (old path: no `Conversion` enqueued; document is `:converted` not `:pending`).

- [ ] **Step 3: Implement**

In `lib/perfect_paper_web/live/new_live.ex`:
- change `@accept ~w(.pdf .docx .txt .md)` → `@accept ~w(.docx)`;
- change `error_text(:not_accepted)` → `"Upload a .docx file."`;
- replace the `consume_uploaded_entries` body's `with` so it pre-checks credits, ingests, and links a session:

```elixir
      consume_uploaded_entries(socket, :manuscript, fn %{path: path}, entry ->
        content = File.read!(path)
        title = Path.rootname(entry.client_name)

        outcome =
          with {:ok, _level} <- History.intended_level(user.id),
               {:ok, document} <-
                 Documents.ingest(user, content, %{
                   filename: entry.client_name,
                   content_type: entry.client_type,
                   source_format: "docx"
                 }),
               {:ok, session} <-
                 History.begin_session(%{user_id: user.id, title: title, document_id: document.id}) do
            {:ok, session}
          end

        {:ok, outcome}
      end)
```

The `case results do` block already handles `[{:ok, %History.Session{} = session}]` (redirect), `[{:error, :no_credits}]` (message), `[]`, and `_`. `intended_level` returns `{:error, :no_credits}` on empty balance, so the existing no-credits branch fires unchanged.

In `lib/perfect_paper_web/live/new_live.html.heex`: add `phx-disable-with="Uploading…"` to the submit button. Ensure the form has a stable id (e.g. `id="manuscript-form"`) matching the test; if it already has one, use that id in the test instead.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/live/new_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/new_live.ex lib/perfect_paper_web/live/new_live.html.heex test/perfect_paper_web/live/new_live_test.exs
git commit -m "feat(web): NewLive docx-only — ingest pipeline, credit pre-check, title-from-filename, disable-with

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: WorkspaceLive — scoped subscribe + converting/ready/failed states

**Files:**
- Modify: `lib/perfect_paper_web/live/workspace_live.ex`
- Test: `test/perfect_paper_web/live/workspace_live_test.exs` (append)

Context — current `mount/3` success branch assigns `canonical_doc` (nil until converted), `active_anchor: nil`, etc. Render passes a `<:document :if={@canonical_doc}>` slot to `review_panes`.

- [ ] **Step 1: Write the failing test**

Append to `test/perfect_paper_web/live/workspace_live_test.exs`:

```elixir
  test "shows Converting… for a pending document, then renders the body on the scoped event",
       %{conn: conn} do
    user = user_fixture()

    {:ok, document} =
      PerfectPaper.Documents.store_and_register(user, "bytes", %{filename: "p.docx", source_format: "docx"})

    {:ok, document} = PerfectPaper.Repo.update(PerfectPaper.Documents.Document.status_changeset(document, :pending))

    {:ok, session} =
      PerfectPaper.History.begin_session(%{user_id: user.id, title: "P", document_id: document.id})

    {:ok, lv, html} = live(log_in_user(conn, user), ~p"/workspace/#{session.id}")
    assert html =~ "Converting"

    # Convert the document, then broadcast the scoped event the worker would send.
    tree = %{"type" => "doc", "content" => [
      %{"type" => "heading", "id" => "n_h", "attrs" => %{"level" => 1},
        "content" => [%{"type" => "text", "text" => "Now Visible"}]}
    ]}
    {:ok, _} = document |> PerfectPaper.Documents.Document.canonical_changeset(%{canonical_doc: tree, status: :converted}) |> PerfectPaper.Repo.update()

    Phoenix.PubSub.broadcast(PerfectPaper.PubSub, "document:#{document.id}", {:document_converted, document.id})

    html = render(lv)
    assert html =~ ~s(id="node-n_h")
    assert html =~ "Now Visible"
  end

  test "shows the failed state on a conversion_failed event", %{conn: conn} do
    user = user_fixture()
    {:ok, document} = PerfectPaper.Documents.register_upload(user, %{filename: "p.docx", source_format: "docx"})
    {:ok, session} = PerfectPaper.History.begin_session(%{user_id: user.id, title: "P", document_id: document.id})

    {:ok, lv, _} = live(log_in_user(conn, user), ~p"/workspace/#{session.id}")
    Phoenix.PubSub.broadcast(PerfectPaper.PubSub, "document:#{document.id}", {:document_conversion_failed, document.id})

    assert render(lv) =~ "couldn't process"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/perfect_paper_web/live/workspace_live_test.exs`
Expected: FAIL (no "Converting" copy; no live update).

- [ ] **Step 3: Implement**

In `mount/3` success branch:
- after computing `canonical`, derive status and subscribe (only when connected):

```elixir
        if connected?(socket) and session.document_id do
          Phoenix.PubSub.subscribe(PerfectPaper.PubSub, "document:#{session.document_id}")
        end

        status = conversion_status(session, canonical)

        {:ok,
         assign(socket,
           page_title: session.title || "Workspace",
           session: session,
           canonical_doc: canonical,
           conversion_status: status,
           active_anchor: nil,
           show_chat: false,
           show_overall: true,
           sort: :relevance
         )}
```

Add the handlers + helper:

```elixir
  @impl true
  def handle_info({:document_converted, _id}, socket) do
    document = Documents.get_document(socket.assigns.session.document_id)
    {:noreply, assign(socket, canonical_doc: Documents.canonical_doc(document), conversion_status: :ready)}
  end

  def handle_info({:document_conversion_failed, _id}, socket) do
    {:noreply, assign(socket, conversion_status: :failed)}
  end

  defp conversion_status(%{document_id: nil}, _canonical), do: :none
  defp conversion_status(_session, canonical) when not is_nil(canonical), do: :ready
  defp conversion_status(_session, _canonical), do: :converting
```

In `render/2`, change the `<:document>` slot so it always renders and switches on status (replace the existing `<:document :if={@canonical_doc}>…</:document>`):

```heex
      <:document>
        <%= case @conversion_status do %>
          <% :ready -> %>
            <PerfectPaperWeb.DocumentComponents.render_tree doc={@canonical_doc} active_anchor={@active_anchor} />
          <% :converting -> %>
            <p class="font-serif text-base-content/70">Converting your manuscript…</p>
          <% :failed -> %>
            <p class="font-serif text-error">We couldn't process that file.</p>
          <% :none -> %>
            <p class="font-serif text-base-content/50">No manuscript attached.</p>
        <% end %>
      </:document>
```

> Because the `:document` slot is now always provided, `review_panes` will render it instead of the faked passages. That's intended for document-backed sessions. If a sibling test relied on the faked-passages fallback for a session *without* a document, `conversion_status: :none` keeps that path benign (or omit the slot when `:none` — implementer's choice, keep it minimal).

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/perfect_paper_web/live/workspace_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/perfect_paper_web/live/workspace_live.ex test/perfect_paper_web/live/workspace_live_test.exs
git commit -m "feat(web): WorkspaceLive scoped subscribe + converting/ready/failed states

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Pre-merge verification + merge

- [ ] **Step 1: Full precommit**

Run: `mix precommit`
Expected: compiles warnings-as-errors, format clean, full suite green (pandoc tests excluded by default).

- [ ] **Step 2: Fix anything red** — broken tests are in scope; do not proceed while any test fails.

- [ ] **Step 3: Sync with main + merge** (main may have advanced)

```bash
git fetch 2>/dev/null || true
git merge --no-edit main        # resolve any config/mix.lock conflicts by regenerating the lock
mix precommit                   # re-verify on the merged tree
git checkout main
git merge --ff-only feat/docx-upload-wiring
```

Expected: clean. Report: "committed and merged back to main with no issues."

---

## Self-Review (completed during authoring)

**Spec coverage:** §3.1 NewLive (Task 5) · §3.2 WorkspaceLive states + scoped subscribe (Task 6) · §3.3 chained review + scoped broadcast + idempotency (Tasks 3, 4) · §6 #1 chaining via Conversion worker + `sessions_for_document/1` (Tasks 2, 4) · §6 #2 best-effort pre-check via `intended_level/1`, no reserve/refund (Tasks 2, 5) · §6 #3 `process_session` on `flatten_text` via `canonical_text/1` (Tasks 2, 3) · `:reviews` queue (Task 1). Out-of-scope (PDF, anchored comments) absent.

**Placeholders:** none in implementation code. Two test-selector notes (Task 5 form id, Task 6 slot fallback) state the concrete contract and tell the implementer to match the real template — flagged, not hidden.

**Type consistency:** review job args `%{"session_id" => id}` consistent across `enqueue_review/1` (Task 2), `ReviewWorker` (Task 3), and the Conversion chain + tests (Task 4); scoped messages `{:document_converted, id}` / `{:document_conversion_failed, id}` consistent across Conversion (Task 4) and WorkspaceLive (Task 6); `Documents.canonical_text/1` shape (string|nil) consistent across Tasks 2, 3, 6.
