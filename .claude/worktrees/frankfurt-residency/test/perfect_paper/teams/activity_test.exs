defmodule PerfectPaper.Teams.ActivityTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Teams.Activity

  @raw %{
    "type" => "message",
    "text" => "Status ",
    "from" => %{"aadObjectId" => "aad-abc-123", "name" => "Alice"},
    "channelData" => %{"tenant" => %{"id" => "tenant-xyz"}},
    "serviceUrl" => "https://smba.trafficmanager.net/",
    "conversation" => %{"id" => "conv-1"},
    "recipient" => %{"id" => "bot-id"},
    "channelId" => "msteams"
  }

  describe "parse/1" do
    test "extracts aad_object_id from from.aadObjectId" do
      act = Activity.parse(@raw)
      assert act.aad_object_id == "aad-abc-123"
    end

    test "extracts tenant_id from channelData.tenant.id" do
      act = Activity.parse(@raw)
      assert act.tenant_id == "tenant-xyz"
    end

    test "extracts service_url from serviceUrl" do
      act = Activity.parse(@raw)
      assert act.service_url == "https://smba.trafficmanager.net/"
    end

    test "trims text whitespace" do
      act = Activity.parse(@raw)
      assert act.text == "Status"
    end

    test "builds conversation_reference with bot/user/conversation/channelId/serviceUrl" do
      act = Activity.parse(@raw)
      ref = act.conversation_reference
      assert ref["bot"] == %{"id" => "bot-id"}
      assert ref["user"] == %{"aadObjectId" => "aad-abc-123", "name" => "Alice"}
      assert ref["conversation"] == %{"id" => "conv-1"}
      assert ref["channelId"] == "msteams"
      assert ref["serviceUrl"] == "https://smba.trafficmanager.net/"
    end

    test "handles missing optional fields gracefully" do
      act = Activity.parse(%{"type" => "ping"})
      assert act.type == "ping"
      assert is_nil(act.aad_object_id)
      assert is_nil(act.tenant_id)
      assert is_nil(act.text)
    end
  end

  describe "command/1" do
    test "returns the lowercased first word of text" do
      act = %Activity{text: "Status please"}
      assert Activity.command(act) == "status"
    end

    test "lowercases a single-word command" do
      act = %Activity{text: "HELP"}
      assert Activity.command(act) == "help"
    end

    test "returns nil when text is nil" do
      act = %Activity{text: nil}
      assert Activity.command(act) == nil
    end

    test "extracts first word from multi-word text" do
      act = %Activity{text: "mute please and thanks"}
      assert Activity.command(act) == "mute"
    end
  end
end
