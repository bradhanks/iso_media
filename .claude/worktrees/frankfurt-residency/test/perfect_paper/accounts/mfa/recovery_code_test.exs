defmodule PerfectPaper.Accounts.MFA.RecoveryCodeTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Accounts.MFA.RecoveryCode

  test "create_changeset requires user_id and code_hash" do
    cs = RecoveryCode.create_changeset(%RecoveryCode{}, %{})
    refute cs.valid?
    assert %{user_id: _, code_hash: _} = errors_on(cs)
  end

  test "accepts a valid recovery code" do
    cs =
      RecoveryCode.create_changeset(%RecoveryCode{}, %{
        user_id: Ecto.UUID.generate(),
        code_hash: "x"
      })

    assert cs.valid?
  end
end
