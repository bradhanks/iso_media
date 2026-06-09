defmodule PerfectPaper.Teams.BotStubTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Teams.Bot

  setup do
    Process.put(:teams_bot_pid, self())
    :ok
  end

  test "send_proactive/2 records {:teams_proactive, ref, card} in the calling process mailbox" do
    ref = %{"a" => 1}
    card = %{}
    assert :ok = Bot.send_proactive(ref, card)
    assert_receive {:teams_proactive, ^ref, ^card}
  end

  test "reply/2 records {:teams_reply, ref, card} in the calling process mailbox" do
    ref = %{"conversation" => %{"id" => "c1"}}
    card = %{"type" => "AdaptiveCard"}
    assert :ok = Bot.reply(ref, card)
    assert_receive {:teams_reply, ^ref, ^card}
  end

  test "send_proactive/2 returns :ok and sends nothing when :teams_bot_pid is not set" do
    Process.delete(:teams_bot_pid)
    assert :ok = Bot.send_proactive(%{}, %{})
    refute_receive {:teams_proactive, _, _}
  end

  test "reply/2 returns :ok and sends nothing when :teams_bot_pid is not set" do
    Process.delete(:teams_bot_pid)
    assert :ok = Bot.reply(%{}, %{})
    refute_receive {:teams_reply, _, _}
  end
end
