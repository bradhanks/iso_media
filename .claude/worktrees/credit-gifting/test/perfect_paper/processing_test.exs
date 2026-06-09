defmodule PerfectPaper.ProcessingTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{History, Processing}
  import PerfectPaper.AccountsFixtures

  describe "snapshot/1" do
    test "counts active and unviewed sessions for a user" do
      user = user_fixture()
      {:ok, _pending} = History.begin_session(%{user_id: user.id, title: "In flight"})

      snapshot = Processing.snapshot(user)

      assert snapshot.active_count == 1
      assert snapshot.unviewed_count == 1
      assert [%{title: "In flight"}] = snapshot.active
    end
  end

  describe "active_items/1 and unviewed_items/1" do
    test "active_items excludes completed sessions; unviewed excludes viewed" do
      user = user_fixture()
      {:ok, active} = History.begin_session(%{user_id: user.id, title: "Active"})
      {:ok, done} = History.begin_session(%{user_id: user.id, title: "Done"})
      {:ok, _completed} = History.finish_session(done, %{overall_feedback: "ok"})

      assert [%{id: id}] = Processing.active_items(user)
      assert id == active.id

      {:ok, _viewed} = History.mark_viewed(active)
      assert Enum.map(Processing.unviewed_items(user), & &1.id) == [done.id]
    end
  end
end
