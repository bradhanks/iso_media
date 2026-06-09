defmodule PerfectPaper.Audit.IngestionCrossCutTest do
  @moduledoc """
  Cross-cut seams found by the iteration-2 adversarial audit (2026-06-06):

    * the Documents canonical SSoT can legitimately flatten to empty text, but
      History assumed non-empty == billable work → a paid LLM call + credit burn
      on an image-only / divider-only / whitespace manuscript;
    * group-owned sessions gated on the OWNER's personal credit balance while
      charging the ORG pool, so org-funded reviews were dead-on-arrival.
  """
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.{Credits, History, Organizations, Repo}
  alias PerfectPaper.History.Session

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.OrganizationsFixtures
  import PerfectPaper.HistoryFixtures

  describe "process_session/2 blank-text guard" do
    test "blank text completes the session without charging a credit or calling the LLM" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 3, "test", :paid)
      session = session_fixture(%{user: user})
      before = Credits.balance(user.id, :paid)

      assert {:ok, completed} = History.process_session(session, "   \n\t  ")
      assert completed.processing_status == :complete
      assert completed.overall_feedback =~ "No reviewable text"
      assert completed.comments == []
      assert Credits.balance(user.id, :paid) == before
    end

    test "an empty string is treated the same as blank" do
      user = user_fixture()
      {:ok, _} = Credits.grant(user.id, 1, "test", :paid)
      session = session_fixture(%{user: user})

      assert {:ok, completed} = History.process_session(session, "")
      assert completed.processing_status == :complete
      assert Credits.balance(user.id, :paid) == 1
    end
  end

  describe "process_session/2 group-owned sessions draw the org pool" do
    test "a funded org pool lets a group session run and charges the pool by 1" do
      owner = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 10})
      group = group_fixture(org)
      session = session_fixture(%{group: group})

      assert {:ok, completed} =
               History.process_session(session, "A genuinely reviewable manuscript paragraph.")

      assert completed.processing_status == :complete
      assert Organizations.credit_pool_status(org.id).pool == 9
    end

    test "a drained pool with no contract yields :no_credits without charging or completing" do
      owner = user_fixture()
      org = organization_fixture(owner, %{credit_pool: 0})
      group = group_fixture(org)
      session = session_fixture(%{group: group})

      assert {:error, :no_credits} =
               History.process_session(session, "A genuinely reviewable manuscript paragraph.")

      assert Organizations.credit_pool_status(org.id).pool == 0
      assert Repo.get!(Session, session.id).processing_status != :complete
    end
  end
end
