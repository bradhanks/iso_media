defmodule PerfectPaper.MarketingTest do
  use PerfectPaper.DataCase, async: true

  alias PerfectPaper.Marketing

  import PerfectPaper.AccountsFixtures

  describe "get_preferences/1" do
    test "returns nil before any preferences are set" do
      user = user_fixture()
      assert is_nil(Marketing.get_preferences(user.id))
    end
  end

  describe "set_opt_in/2" do
    test "persists opt_in true for the user" do
      user = user_fixture()
      assert {:ok, pref} = Marketing.set_opt_in(user, true)
      assert pref.user_id == user.id
      assert pref.opt_in == true
    end

    test "persists opt_in false for the user" do
      user = user_fixture()
      assert {:ok, pref} = Marketing.set_opt_in(user, false)
      assert pref.opt_in == false
    end

    test "upserts — calling twice produces only one row and toggles the value" do
      user = user_fixture()
      {:ok, _pref1} = Marketing.set_opt_in(user, true)
      {:ok, pref2} = Marketing.set_opt_in(user, false)

      assert pref2.opt_in == false

      # Confirm only one row exists for this user
      stored = Marketing.get_preferences(user.id)
      assert stored.id == pref2.id
      assert stored.opt_in == false
    end

    test "get_preferences returns the saved preference after set_opt_in" do
      user = user_fixture()
      {:ok, pref} = Marketing.set_opt_in(user, true)
      fetched = Marketing.get_preferences(user.id)
      assert fetched.id == pref.id
      assert fetched.opt_in == true
    end
  end
end
