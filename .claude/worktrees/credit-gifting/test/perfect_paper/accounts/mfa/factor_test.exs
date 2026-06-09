defmodule PerfectPaper.Accounts.MFA.FactorTest do
  use PerfectPaper.DataCase, async: true
  alias PerfectPaper.Accounts.MFA.Factor

  test "create_changeset requires user_id and type" do
    cs = Factor.create_changeset(%Factor{}, %{})
    refute cs.valid?
    errors = errors_on(cs)
    assert Map.has_key?(errors, :user_id)
    assert Map.has_key?(errors, :type)
  end

  test "accepts a valid totp factor" do
    cs =
      Factor.create_changeset(%Factor{}, %{
        user_id: Ecto.UUID.generate(),
        type: :totp,
        label: "phone"
      })

    assert cs.valid?
  end

  test "rejects an unknown factor type" do
    cs = Factor.create_changeset(%Factor{}, %{user_id: Ecto.UUID.generate(), type: :sms})
    refute cs.valid?
  end
end
