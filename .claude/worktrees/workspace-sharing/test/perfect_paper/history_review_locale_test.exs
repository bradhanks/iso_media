defmodule PerfectPaper.HistoryReviewLocaleTest do
  # async: false — swaps the global :llm_provider, so it must not run
  # concurrently with tests that rely on the real stub.
  use PerfectPaper.DataCase, async: false

  alias PerfectPaper.{Accounts, Credits, History}

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  # Records the locale handed to the LLM review call so the test can assert the
  # session owner's language flowed all the way through.
  defmodule LocaleRecordingLLM do
    @behaviour PerfectPaper.Chatbot.LLM
    @impl true
    def complete(_messages, _opts \\ []), do: {:ok, %{role: :assistant, content: "x"}}

    @impl true
    def review(_text, _system, opts) do
      if pid = Application.get_env(:perfect_paper, :locale_recording_pid),
        do: send(pid, {:review_locale, Keyword.get(opts, :locale)})

      {:ok, %{overall_feedback: "ok", comments: []}}
    end
  end

  setup do
    prev = Application.get_env(:perfect_paper, :llm_provider)
    Application.put_env(:perfect_paper, :llm_provider, LocaleRecordingLLM)
    Application.put_env(:perfect_paper, :locale_recording_pid, self())

    on_exit(fn ->
      Application.put_env(:perfect_paper, :llm_provider, prev)
      Application.delete_env(:perfect_paper, :locale_recording_pid)
    end)

    :ok
  end

  test "the review is generated in the session owner's locale" do
    user = user_fixture()
    {:ok, _} = Accounts.update_user_locale(user, "de")
    {:ok, _} = Credits.grant(user.id, 1, "test", :paid)
    session = session_fixture(user: user)

    assert {:ok, _} = History.process_session(session, "manuscript text")
    assert_receive {:review_locale, "de"}
  end

  test "defaults to English when the owner is on the default locale" do
    user = user_fixture()
    {:ok, _} = Credits.grant(user.id, 1, "test", :paid)
    session = session_fixture(user: user)

    assert {:ok, _} = History.process_session(session, "manuscript text")
    assert_receive {:review_locale, "en"}
  end
end
