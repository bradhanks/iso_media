defmodule PerfectPaper.Accounts.OAuth.AssentTest do
  use ExUnit.Case, async: true

  alias PerfectPaper.Accounts.OAuth.Assent, as: Adapter

  test "normalises OIDC-style claims (Google)" do
    claims = %{
      "sub" => "108",
      "email" => "p@example.com",
      "email_verified" => true,
      "name" => "Pat"
    }

    assert Adapter.normalize("google", claims) == %{
             provider: "google",
             uid: "108",
             email: "p@example.com",
             email_verified: true,
             name: "Pat"
           }
  end

  test "honours the provider's verified flag (GitHub primary email reported verified)" do
    claims = %{
      "sub" => "42",
      "email" => "dev@example.com",
      "email_verified" => true,
      "name" => "Dev"
    }

    identity = Adapter.normalize("github", claims)
    assert identity.uid == "42"
    assert identity.email == "dev@example.com"
    assert identity.email_verified == true
  end

  test "an email the provider does NOT report verified is treated as unverified" do
    claims = %{"sub" => "42", "email" => "dev@example.com", "name" => "Dev"}
    assert Adapter.normalize("github", claims).email_verified == false
  end

  test "no email is unverified with nil email" do
    identity = Adapter.normalize("github", %{"sub" => "42"})
    assert identity.email == nil
    assert identity.email_verified == false
  end

  test "authorize_url errors for an unconfigured provider" do
    assert {:error, :unconfigured_provider} = Adapter.authorize_url("google")
  end
end
