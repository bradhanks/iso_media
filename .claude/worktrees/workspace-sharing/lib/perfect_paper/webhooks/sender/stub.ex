defmodule PerfectPaper.Webhooks.Sender.Stub do
  @moduledoc """
  Test sender stub. Records each call via `send(self(), {:webhook_delivered, ...})` so
  tests can assert on URL, headers, and body. Returns the result stored in the process
  dictionary under `:webhook_stub_result` (defaults to `{:ok, 200}`).

  The Oban worker runs in the test process when using `Oban.Testing.perform_job/2`, so
  `send(self(), ...)` and `Process.get` are reliable within a single test.

  Override the stub result in a test with:

      Process.put(:webhook_stub_result, {:ok, 500})   # or {:error, :timeout}
  """

  @behaviour PerfectPaper.Webhooks.Sender

  @impl true
  @spec deliver(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, integer()} | {:error, term()}
  def deliver(url, body, headers) do
    send(self(), {:webhook_delivered, %{url: url, body: body, headers: headers}})
    Process.get(:webhook_stub_result, {:ok, 200})
  end
end
