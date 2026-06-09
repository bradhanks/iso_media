defmodule PerfectPaper.Accounts.UserNotifier do
  @moduledoc """
  Builds and sends the Accounts context's transactional emails (account
  confirmation, magic-link login, email-change instructions, and the welcome
  email) using the shared branded `PerfectPaper.Email` layer.

  Each email carries both a branded HTML body and a plaintext fallback; the
  action URL appears in both so text-only clients (and the test token
  extractor) can still reach it.
  """
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email
  alias PerfectPaper.Accounts.User

  @doc "Deliver instructions to update a user's email address."
  @spec deliver_update_email_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_update_email_instructions(user, url) do
    assigns = %{email: user.email, url: url}

    body = ~H"""
    <.document preview="Confirm your new email address">
      <.eyebrow>Email change</.eyebrow>
      <p>Hi {@email},</p>
      <p>You can change the email on your PerfectPaper account by tapping the button below.</p>
      <.button href={@url}>Confirm new email</.button>
      <p style="font-size:14px;color:#6b6259;">
        If you didn't request this change, you can safely ignore this email.
      </p>
    </.document>
    """

    text = """
    Hi #{user.email},

    You can change your PerfectPaper email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this email.
    """

    Email.deliver(user.email, "Update your email", body, text)
  end

  @doc """
  Deliver login instructions. Unconfirmed users get account-confirmation copy;
  confirmed users get magic-link login copy.
  """
  @spec deliver_login_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  @doc "Deliver the warm welcome email after a user first confirms their account."
  @spec deliver_welcome(User.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_welcome(user) do
    url = home_url()
    assigns = %{email: user.email, url: url}

    body = ~H"""
    <.document preview="Welcome to PerfectPaper — let's polish your first paper">
      <.eyebrow>Welcome aboard</.eyebrow>
      <p>Hi {@email},</p>
      <p>
        Welcome to PerfectPaper, your AI peer reviewer for academic papers. Upload a
        draft and you'll get measured, constructive feedback as comments you can
        accept, address, or set aside — the way a thoughtful colleague would mark it up.
      </p>
      <p>
        There's a free credit waiting on your account. The best way to start is to put it to work.
      </p>
      <.button href={@url}>Review your first paper</.button>
      <p style="font-size:14px;color:#6b6259;">We're glad you're here.</p>
    </.document>
    """

    text = """
    Hi #{user.email},

    Welcome to PerfectPaper, your AI peer reviewer for academic papers. Upload a
    draft and you'll get measured, constructive feedback as comments you can
    accept, address, or set aside.

    There's a free credit waiting on your account — the best way to start is to
    put it to work. Sign in and review your first paper:

    #{url}

    We're glad you're here.
    """

    Email.deliver(user.email, "Welcome to PerfectPaper", body, text)
  end

  defp deliver_magic_link_instructions(user, url) do
    assigns = %{email: user.email, url: url}

    body = ~H"""
    <.document preview="Your PerfectPaper sign-in link">
      <.eyebrow>Sign in</.eyebrow>
      <p>Hi {@email},</p>
      <p>
        Tap the button below to log in to PerfectPaper. The link is single-use and expires shortly.
      </p>
      <.button href={@url}>Log in to PerfectPaper</.button>
      <p style="font-size:14px;color:#6b6259;">
        If you didn't request this link, you can safely ignore this email.
      </p>
    </.document>
    """

    text = """
    Hi #{user.email},

    You can log in to PerfectPaper by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore it.
    """

    Email.deliver(user.email, "Your PerfectPaper sign-in link", body, text)
  end

  defp deliver_confirmation_instructions(user, url) do
    assigns = %{email: user.email, url: url}

    body = ~H"""
    <.document preview="Confirm your PerfectPaper account">
      <.eyebrow>Confirm your account</.eyebrow>
      <p>Hi {@email},</p>
      <p>
        Welcome to PerfectPaper. Confirm your account by tapping the button below and you'll be ready to review your first paper.
      </p>
      <.button href={@url}>Confirm my account</.button>
      <p style="font-size:14px;color:#6b6259;">
        If you didn't create a PerfectPaper account, you can safely ignore this email.
      </p>
    </.document>
    """

    text = """
    Hi #{user.email},

    Welcome to PerfectPaper. You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this email.
    """

    Email.deliver(user.email, "Confirm your PerfectPaper account", body, text)
  end

  defp home_url, do: PerfectPaperWeb.Endpoint.url()
end
