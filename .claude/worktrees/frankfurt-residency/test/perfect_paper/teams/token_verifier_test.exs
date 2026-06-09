defmodule PerfectPaper.Teams.TokenVerifierTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Teams.TokenVerifier

  test "default stub accepts" do
    assert {:ok, _claims} = TokenVerifier.verify("Bearer x", "https://smba.example/")
  end

  test "stub can be forced to reject" do
    Process.put(:teams_verify, {:error, :invalid_signature})

    assert {:error, :invalid_signature} =
             TokenVerifier.verify("Bearer x", "https://smba.example/")
  end
end
