defmodule PerfectPaper.Audit.ProcessSessionIdempotencyTest do
  @moduledoc "Audit fix: process_session must not re-charge / re-run a paid review on an already-complete session."
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.{History, Credits, Repo}
  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  test "process_session on an already-complete session is a no-op (no re-charge, no re-review)" do
    user = user_fixture()
    {:ok, _} = Credits.grant(user.id, 5, "test", :paid)
    before = Credits.balance(user.id)

    session = session_fixture(%{user: user})
    {:ok, complete} = Repo.update(Ecto.Changeset.change(session, processing_status: :complete))

    # Must short-circuit: return the session untouched, charge nothing, call no LLM.
    assert {:ok, returned} = History.process_session(complete, "irrelevant document text")
    assert returned.id == complete.id
    assert returned.processing_status == :complete
    assert Credits.balance(user.id) == before
  end
end
