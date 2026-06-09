defmodule PerfectPaper.AccountsTest do
  use PerfectPaper.DataCase

  alias PerfectPaper.Accounts

  import PerfectPaper.AccountsFixtures
  alias PerfectPaper.Accounts.{User, UserToken}
  alias PerfectPaper.Credits

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!("11111111-1111-1111-1111-111111111111")
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)
    end

    test "dispatches the :signup credit campaign (with email) for self-initiated sign-ups" do
      Credits.subscribe()
      email = unique_user_email()
      {:ok, _user} = Accounts.register_user(valid_user_attributes(email: email))
      # email travels in the payload so the campaign's academic-domain gate can read it
      assert_receive {:signup, %{user_id: _, email: ^email}}, 200
    end
  end

  describe "academic_email?/1" do
    test "accepts US .edu/.gov/.mil" do
      assert Accounts.academic_email?("a@stanford.edu")
      assert Accounts.academic_email?("b@nasa.gov")
      assert Accounts.academic_email?("c@army.mil")
    end

    test "accepts common international second-level academic/gov domains" do
      assert Accounts.academic_email?("d@some.ox.ac.uk")
      assert Accounts.academic_email?("e@anu.edu.au")
      assert Accounts.academic_email?("f@dept.gov.uk")
      assert Accounts.academic_email?("g@x.gob.mx")
    end

    test "is case- and whitespace-insensitive" do
      assert Accounts.academic_email?("  Scholar@Stanford.EDU ")
    end

    test "rejects consumer/commercial domains and malformed input" do
      refute Accounts.academic_email?("h@gmail.com")
      refute Accounts.academic_email?("i@education.com")
      refute Accounts.academic_email?("j@my-edu.org")
      refute Accounts.academic_email?("not-an-email")
      refute Accounts.academic_email?(nil)
      refute Accounts.academic_email?("")
    end
  end

  describe "find_or_create_guest/1" do
    test "returns the existing user when the email is already registered" do
      user = user_fixture()
      assert {:ok, found} = Accounts.find_or_create_guest(user.email)
      assert found.id == user.id
    end

    test "creates a new passwordless user when the email is unknown" do
      email = unique_user_email()
      assert {:ok, guest} = Accounts.find_or_create_guest(email)
      assert guest.email == email
      assert is_nil(guest.hashed_password)
    end

    test "returns an error changeset for an invalid email" do
      assert {:error, changeset} = Accounts.find_or_create_guest("not-an-email")
      assert errors_on(changeset)[:email]
    end

    test "does NOT dispatch the :signup credit campaign for a newly created guest" do
      Credits.subscribe()
      email = unique_user_email()
      {:ok, _guest} = Accounts.find_or_create_guest(email)
      refute_receive {:signup, _}, 100
    end

    test "does NOT dispatch the :signup credit campaign for an existing user found by guest lookup" do
      user = user_fixture()
      # Subscribe after fixture creation so the fixture's own :signup broadcast
      # (from register_user) is not in our mailbox.
      Credits.subscribe()
      {:ok, _found} = Accounts.find_or_create_guest(user.email)
      refute_receive {:signup, _}, 100
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "revokes every existing session token (logout everywhere)", %{
      user: user,
      token: token
    } do
      session_token = Accounts.generate_user_session_token(user)
      assert Accounts.get_user_by_session_token(session_token)

      assert {:ok, _} = Accounts.update_user_email(user, token)

      refute Accounts.get_user_by_session_token(session_token)
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "mfa_required_for?/1" do
    import PerfectPaper.OrganizationsFixtures

    test "false for a plain user with no factors and no org policy" do
      refute PerfectPaper.Accounts.mfa_required_for?(user_fixture())
    end

    test "true when the user opted in (mfa_enabled)" do
      user = user_fixture()
      {:ok, user} = PerfectPaper.Accounts.set_mfa_enabled(user, true)
      assert PerfectPaper.Accounts.mfa_required_for?(user)
    end

    test "true when one of the user's orgs requires MFA" do
      user = user_fixture()
      org = organization_fixture(user, %{mfa_required: true})
      membership_fixture(org, user, :member)
      assert PerfectPaper.Accounts.mfa_required_for?(user)
    end
  end

  # ─── promote_guest ────────────────────────────────────────────────────────────

  describe "promote_guest/2 — SSO mode" do
    test "confirms an invited guest and fires :signup exactly once" do
      # find_or_create_guest creates an unconfirmed, passwordless, uncredited user
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())
      refute guest.confirmed_at
      assert is_nil(guest.hashed_password)

      Credits.subscribe()

      assert {:ok, promoted} = Accounts.promote_guest(guest, :sso)

      # confirmed
      assert promoted.confirmed_at
      # password still nil — SSO mode must never touch hashed_password
      assert is_nil(promoted.hashed_password)
      # :signup dispatched exactly once
      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "is idempotent — second call does NOT fire :signup again" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())

      # First promotion — apply and wait for the broadcast so the grant is
      # recorded before the second call.
      Credits.subscribe()
      {:ok, _} = Accounts.promote_guest(guest, :sso)
      assert_receive {:signup, %{user_id: _}}, 500

      # Second promotion on the same user
      # Re-fetch so confirmed_at is set (changeset won't error on already-confirmed)
      promoted = Accounts.get_user!(guest.id)
      {:ok, _} = Accounts.promote_guest(promoted, :sso)

      # No second :signup broadcast
      refute_receive {:signup, _}, 200
    end

    test "hashed_password remains nil after SSO promotion" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())
      Credits.subscribe()
      {:ok, promoted} = Accounts.promote_guest(guest, :sso)
      assert is_nil(promoted.hashed_password)
      # drain
      assert_receive {:signup, _}, 500
    end
  end

  describe "promote_guest/3 — password mode" do
    test "confirms the guest, sets the password, and fires :signup once" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())
      Credits.subscribe()

      assert {:ok, promoted} =
               Accounts.promote_guest(guest, :password, %{password: "longenoughpassword"})

      assert promoted.confirmed_at
      assert promoted.hashed_password
      assert is_nil(promoted.password)

      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "returns a changeset error for a too-short password" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())

      assert {:error, changeset} =
               Accounts.promote_guest(guest, :password, %{password: "short"})

      assert %{password: [_ | _]} = errors_on(changeset)
      # else Phoenix hides inline form errors
      assert changeset.action == :update
    end
  end

  describe "promote_guest — idempotency against already-credited users" do
    test "magic-link self-signup (already credited) → promote_guest :sso does NOT double-credit" do
      # register_user dispatches :signup; subscribe AFTER so we don't catch that one
      {:ok, user} = Accounts.register_user(valid_user_attributes())

      Credits.subscribe()
      {:ok, _} = Accounts.promote_guest(user, :sso)

      refute_receive {:signup, _}, 200
    end
  end

  describe "register_user/1 — guest promotion path" do
    test "promotes an existing guest instead of returning :email_taken" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())
      refute guest.confirmed_at
      Credits.subscribe()

      # register_user on the same email should promote the guest, not error
      assert {:ok, promoted} = Accounts.register_user(%{email: guest.email})
      assert promoted.id == guest.id
      assert promoted.confirmed_at
      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "brand-new email → normal signup (no pre-existing user)" do
      Credits.subscribe()
      email = unique_user_email()
      assert {:ok, user} = Accounts.register_user(%{email: email})
      assert user.email == email
      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "existing full member (confirmed + credited) → unchanged :email_taken error" do
      # user_fixture() creates a confirmed, credited full member
      %{email: email} = user_fixture()
      assert {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "register_user_with_password/1 — guest promotion path" do
    test "promotes an existing guest with a password instead of returning :email_taken" do
      {:ok, guest} = Accounts.find_or_create_guest(unique_user_email())
      Credits.subscribe()

      assert {:ok, promoted} =
               Accounts.register_user_with_password(%{
                 email: guest.email,
                 password: "longenoughpassword"
               })

      assert promoted.id == guest.id
      assert promoted.confirmed_at
      assert promoted.hashed_password
      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "brand-new email → normal password signup" do
      Credits.subscribe()

      assert {:ok, user} =
               Accounts.register_user_with_password(%{
                 email: unique_user_email(),
                 password: "longenoughpassword"
               })

      assert user.hashed_password
      assert_receive {:signup, %{user_id: _}}, 500
    end

    test "existing full member → unchanged :email_taken error" do
      %{email: email} = user_fixture()

      assert {:error, changeset} =
               Accounts.register_user_with_password(%{
                 email: email,
                 password: "longenoughpassword"
               })

      assert "has already been taken" in errors_on(changeset).email
    end
  end
end
