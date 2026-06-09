defmodule PerfectPaper.Accounts.MFATest do
  use ExUnit.Case, async: true
  alias PerfectPaper.Accounts.MFA

  test "begin_enrollment is stubbed (not implemented yet) for both types" do
    assert MFA.begin_enrollment(%{id: Ecto.UUID.generate()}, :totp) == {:error, :not_implemented}

    assert MFA.begin_enrollment(%{id: Ecto.UUID.generate()}, :webauthn) ==
             {:error, :not_implemented}
  end

  test "verify is stubbed" do
    assert MFA.verify(%{id: Ecto.UUID.generate()}, :totp, "000000") == {:error, :not_implemented}
  end
end
