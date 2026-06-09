defmodule PerfectPaper.HistoryChargeOnSuccessTest do
  # async: false — swaps the global :llm_provider to a failing adapter, so it
  # must not run concurrently with tests that rely on the real stub.
  use PerfectPaper.DataCase, async: false

  alias PerfectPaper.{Credits, History}

  import PerfectPaper.AccountsFixtures
  import PerfectPaper.HistoryFixtures

  defmodule FailingLLM do
    @behaviour PerfectPaper.Chatbot.LLM
    @impl true
    def complete(_messages, _opts \\ []), do: {:error, :boom}
    @impl true
    def review(_text, _system, _opts), do: {:error, :provider_down}
  end

  setup do
    previous = Application.get_env(:perfect_paper, :llm_provider)
    Application.put_env(:perfect_paper, :llm_provider, FailingLLM)
    on_exit(fn -> Application.put_env(:perfect_paper, :llm_provider, previous) end)
    :ok
  end

  test "a failed review does not consume the writer's credit" do
    user = user_fixture()
    {:ok, _} = Credits.grant(user.id, 1, "test", :paid)
    session = session_fixture(user: user)

    assert {:error, :provider_down} = History.process_session(session, "manuscript text")

    # The credit was NOT spent because the review failed before the charge.
    assert Credits.balance(user.id) == 1
  end
end
