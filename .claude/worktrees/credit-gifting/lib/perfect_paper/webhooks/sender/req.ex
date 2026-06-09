defmodule PerfectPaper.Webhooks.Sender.Req do
  @moduledoc "Default outbound webhook sender using the Req HTTP client."

  @behaviour PerfectPaper.Webhooks.Sender

  @impl true
  @spec deliver(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, integer()} | {:error, term()}
  def deliver(url, body, headers) do
    case Req.post(url, body: body, headers: headers, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
