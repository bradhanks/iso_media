defmodule PerfectPaper.ReferralsTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Referrals

  import PerfectPaper.AccountsFixtures

  describe "register/2" do
    test "creates a referral with a non-nil code and :pending status" do
      user = user_fixture()
      assert {:ok, referral} = Referrals.register(user)
      assert referral.referrer_user_id == user.id
      assert is_binary(referral.referral_code)
      assert String.starts_with?(referral.referral_code, "pp-")
      assert referral.status == :pending
      assert is_nil(referral.referee_user_id)
    end

    test "accepts an optional referee_user_id" do
      referrer = user_fixture()
      referee = user_fixture()
      assert {:ok, referral} = Referrals.register(referrer, referee_user_id: referee.id)
      assert referral.referee_user_id == referee.id
    end

    test "generates unique codes across multiple registrations" do
      user = user_fixture()
      {:ok, r1} = Referrals.register(user)
      {:ok, r2} = Referrals.register(user)
      refute r1.referral_code == r2.referral_code
    end
  end

  describe "status/1" do
    test "returns all referrals for the given referrer, newest first" do
      user = user_fixture()
      other_user = user_fixture()

      {:ok, r1} = Referrals.register(user)
      {:ok, r2} = Referrals.register(user)
      {:ok, _other} = Referrals.register(other_user)

      results = Referrals.status(user.id)

      assert length(results) == 2
      ids = Enum.map(results, & &1.id)
      assert r1.id in ids
      assert r2.id in ids
    end

    test "returns an empty list when the user has no referrals" do
      user = user_fixture()
      assert Referrals.status(user.id) == []
    end
  end

  describe "accept_referral/2" do
    test "links the referee to the code's referrer and marks it accepted" do
      referrer = user_fixture()
      referee = user_fixture()
      {:ok, ref} = Referrals.register(referrer)

      assert {:ok, accepted} = Referrals.accept_referral(ref.referral_code, referee)
      assert accepted.referee_user_id == referee.id
      assert accepted.status == :accepted
      assert Referrals.referrer_id_for(referee.id) == referrer.id
    end

    test "rejects a self-referral" do
      user = user_fixture()
      {:ok, ref} = Referrals.register(user)
      assert {:error, :unavailable} = Referrals.accept_referral(ref.referral_code, user)
      assert Referrals.referrer_id_for(user.id) == nil
    end

    test "rejects an already-claimed code" do
      referrer = user_fixture()
      {:ok, ref} = Referrals.register(referrer)
      {:ok, _} = Referrals.accept_referral(ref.referral_code, user_fixture())

      assert {:error, :unavailable} = Referrals.accept_referral(ref.referral_code, user_fixture())
    end

    test "rejects a referee who was already referred by someone else" do
      {:ok, r1} = Referrals.register(user_fixture())
      {:ok, r2} = Referrals.register(user_fixture())
      referee = user_fixture()

      {:ok, _} = Referrals.accept_referral(r1.referral_code, referee)
      assert {:error, :unavailable} = Referrals.accept_referral(r2.referral_code, referee)
    end

    test "rejects an unknown, empty, or nil code" do
      referee = user_fixture()
      assert {:error, :unavailable} = Referrals.accept_referral("pp-nope", referee)
      assert {:error, :unavailable} = Referrals.accept_referral("", referee)
      assert {:error, :unavailable} = Referrals.accept_referral(nil, referee)
    end
  end
end
