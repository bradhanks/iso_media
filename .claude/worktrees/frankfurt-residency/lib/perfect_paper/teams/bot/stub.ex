defmodule PerfectPaper.Teams.Bot.Stub do
  @moduledoc """
  Recording stub for `Teams.Bot`. In tests, call
  `Process.put(:teams_bot_pid, self())` before exercising code that sends
  outbound cards — the stub will `send/2` the recorded message to that pid so
  you can `assert_receive`.

  Messages sent:
    - `{:teams_reply, conversation_reference, card}` from `reply/2`
    - `{:teams_proactive, conversation_reference, card}` from `send_proactive/2`
  """

  @behaviour PerfectPaper.Teams.Bot

  @impl true
  def reply(ref, card), do: record({:teams_reply, ref, card})

  @impl true
  def send_proactive(ref, card), do: record({:teams_proactive, ref, card})

  defp record(msg) do
    if pid = Process.get(:teams_bot_pid), do: send(pid, msg)
    :ok
  end
end
