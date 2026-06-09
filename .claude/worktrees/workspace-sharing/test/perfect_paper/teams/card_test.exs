defmodule PerfectPaper.Teams.CardTest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Teams.Card

  describe "card/1" do
    test "wraps body with version 1.4 and schema" do
      result = Card.card([%{"type" => "TextBlock", "text" => "hello"}])
      assert result["version"] == "1.4"
      assert result["type"] == "AdaptiveCard"
      assert result["$schema"] == "http://adaptivecards.io/schemas/adaptive-card.json"
      assert length(result["body"]) == 1
    end
  end

  describe "event/2" do
    test "session.completed returns version 1.4 and title in body" do
      result = Card.event(:"session.completed", %{title: "Doc"})
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "Doc"))
    end

    test "comment.added returns version 1.4 and title in body" do
      result = Card.event(:"comment.added", %{title: "My Paper"})
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "My Paper"))
    end

    test "session.shared returns version 1.4 and title in body" do
      result = Card.event(:"session.shared", %{title: "Shared Doc"})
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "Shared Doc"))
    end
  end

  describe "status/1" do
    test "empty list returns a card with 'No recent reviews'" do
      result = Card.status([])
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "No recent reviews"))
    end

    test "non-empty list differs from empty list result" do
      empty_result = Card.status([])
      non_empty_result = Card.status([%{title: "T", state: "complete"}])
      assert empty_result != non_empty_result
    end

    test "non-empty list includes session titles and states" do
      result = Card.status([%{title: "T", state: "complete"}])
      body_texts = Enum.map(result["body"], & &1["text"])

      assert Enum.any?(
               body_texts,
               &(String.contains?(&1, "T") and String.contains?(&1, "complete"))
             )
    end
  end

  describe "link_prompt/1" do
    test "contains an Action.OpenUrl action with the given url" do
      url = "https://x"
      result = Card.link_prompt(url)
      assert result["version"] == "1.4"
      actions = result["actions"]
      assert is_list(actions)

      assert Enum.any?(actions, fn a ->
               a["type"] == "Action.OpenUrl" and a["url"] == url
             end)
    end
  end

  describe "help/0" do
    test "returns a version 1.4 card with command instructions" do
      result = Card.help()
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "status"))
    end
  end

  describe "welcome/1" do
    test "returns a version 1.4 card mentioning the user's name" do
      result = Card.welcome("Alice")
      assert result["version"] == "1.4"
      body_texts = Enum.map(result["body"], & &1["text"])
      assert Enum.any?(body_texts, &String.contains?(&1, "Alice"))
    end
  end
end
