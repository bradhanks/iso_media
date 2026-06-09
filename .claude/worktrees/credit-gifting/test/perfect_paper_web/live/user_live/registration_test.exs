defmodule PerfectPaperWeb.UserLive.RegistrationTest do
  # async: false — the "social buttons" test mutates the global
  # `:oauth_providers` application env, which `Accounts.configured_providers/0`
  # and the OAuth adapter read. Run sync so it can't leak into async tests that
  # assert a provider is *un*configured (e.g. OAuth.AssentTest).
  use PerfectPaperWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PerfectPaper.AccountsFixtures

  alias PerfectPaper.Accounts

  # The web-layer rate limiter is process-global ETS keyed by client IP. In an
  # async file every test would otherwise resolve to the same IP and contend on
  # one bucket, so give each test its own IP via x-forwarded-for.
  setup %{conn: conn} do
    ip = "203.0.113.#{System.unique_integer([:positive])}"
    {:ok, conn: put_req_header(conn, "x-forwarded-for", ip)}
  end

  # An academic email registers directly (no free-credit nudge); a consumer email
  # opens the nudge instead. Tests of the core registration mechanics use the
  # academic form so they bypass the modal.
  defp academic_email, do: "scholar#{System.unique_integer([:positive])}@mit.edu"
  defp consumer_email, do: "writer#{System.unique_integer([:positive])}@gmail.com"

  describe "Registration page" do
    test "renders the magic-link registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Send magic link"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/new")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid email format", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "must have the @ sign and no spaces"
    end

    test "shows social buttons when a provider is configured", %{conn: conn} do
      Application.put_env(:perfect_paper, :oauth_providers, %{
        "google" => [client_id: "x", client_secret: "y"]
      })

      on_exit(fn -> Application.put_env(:perfect_paper, :oauth_providers, %{}) end)

      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "/auth/google"
    end
  end

  describe "register user" do
    test "new academic email: creates user and shows check-email state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = academic_email()

      html =
        lv
        |> form("#registration_form", user: %{"email" => email})
        |> render_submit()

      assert html =~ "Check your email"
      assert html =~ email
      assert Accounts.get_user_by_email(email)
    end

    test "new email arriving via a referral code links the new user to the referrer", %{
      conn: conn
    } do
      referrer = user_fixture()
      {:ok, ref} = PerfectPaper.Referrals.register(referrer)
      email = unique_user_email()

      conn = Plug.Test.init_test_session(conn, %{"referral_code" => ref.referral_code})
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      lv
      |> form("#registration_form", user: %{"email" => email})
      |> render_submit()

      new_user = Accounts.get_user_by_email(email)
      assert new_user
      assert PerfectPaper.Referrals.referrer_id_for(new_user.id) == referrer.id
    end

    test "existing email: same check-email state, no enumeration", %{conn: conn} do
      user = user_fixture(%{email: academic_email()})
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html =
        lv
        |> form("#registration_form", user: %{"email" => user.email})
        |> render_submit()

      assert html =~ "Check your email"
      refute html =~ "has already been taken"

      # Anti-enumeration's other half: the existing user is actually sent a
      # login link (a "login" token is created), so the identical UI isn't a
      # silent no-op for known emails.
      assert PerfectPaper.Repo.get_by!(PerfectPaper.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "rate limited: 6th submit shows check-email but neither registers nor sends", %{
      conn: conn
    } do
      # The form transitions in-place to the check-email state on submit, so each
      # send needs a fresh mount. All mounts share the same per-IP bucket
      # (5/min), so the first five succeed and the sixth is throttled.
      for _ <- 1..5 do
        {:ok, lv, _html} = live(conn, ~p"/users/register")

        lv
        |> form("#registration_form", user: %{"email" => academic_email()})
        |> render_submit()
      end

      throttled_email = academic_email()
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      html =
        lv
        |> form("#registration_form", user: %{"email" => throttled_email})
        |> render_submit()

      # Anti-enumeration: the throttled submit still lands on the identical
      # check-email state, but it must NOT have registered the account or sent a
      # link — proving the limiter suppresses the action, not just the UI.
      assert html =~ "Check your email"
      refute Accounts.get_user_by_email(throttled_email)
    end
  end

  describe "free-credit academic nudge" do
    test "an academic email registers directly, no nudge", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = academic_email()

      html = lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()

      assert html =~ "Check your email"
      refute html =~ "Claim a free review credit"
      assert Accounts.get_user_by_email(email)
    end

    test "a consumer email opens the nudge instead of registering", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = consumer_email()

      html = lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()

      assert html =~ "Claim a free review credit"
      refute Accounts.get_user_by_email(email)
    end

    test "'No thanks' registers the original consumer email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = consumer_email()

      lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()
      html = lv |> element("#nudge-no-thanks") |> render_click()

      assert html =~ "Check your email"
      assert Accounts.get_user_by_email(email)
    end

    test "'Get my free credit' with an academic email registers that email instead", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      consumer = consumer_email()
      academic = academic_email()

      lv |> form("#registration_form", user: %{"email" => consumer}) |> render_submit()
      lv |> element("#nudge-get-credit") |> render_click()
      html = lv |> form("#nudge-email-form", nudge: %{"email" => academic}) |> render_submit()

      assert html =~ "Check your email"
      assert Accounts.get_user_by_email(academic)
      refute Accounts.get_user_by_email(consumer)
    end

    test "a non-academic email inside the nudge is a validation error, not a registration", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      consumer = consumer_email()
      other_consumer = consumer_email()

      lv |> form("#registration_form", user: %{"email" => consumer}) |> render_submit()
      lv |> element("#nudge-get-credit") |> render_click()

      html =
        lv |> form("#nudge-email-form", nudge: %{"email" => other_consumer}) |> render_submit()

      assert html =~ "eligible international email"
      refute Accounts.get_user_by_email(other_consumer)
    end

    test "closing the nudge lets the next submit register the original email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = consumer_email()

      lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()
      # close the modal — the warning won't reappear
      render_click(lv, "nudge_close")

      html = lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()

      assert html =~ "Check your email"
      refute html =~ "Claim a free review credit"
      assert Accounts.get_user_by_email(email)
    end

    test "Back returns to the warning so 'No thanks' can submit as-is", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")
      email = consumer_email()

      lv |> form("#registration_form", user: %{"email" => email}) |> render_submit()
      lv |> element("#nudge-get-credit") |> render_click()
      html = lv |> element("#nudge-back") |> render_click()
      assert html =~ "Claim a free review credit"

      html = lv |> element("#nudge-no-thanks") |> render_click()
      assert html =~ "Check your email"
      assert Accounts.get_user_by_email(email)
    end
  end
end
