defmodule PerfectPaper.Referrals.Notifier do
  @moduledoc """
  Builds and sends the Referrals context's showcase emails: the referral
  invitation (to a friend) and the reward-earned notice (to the referrer).
  Uses the shared branded `PerfectPaper.Email` layer. These are the warmest,
  most celebratory emails in the product.
  """
  use Phoenix.Component

  import PerfectPaper.Email.Layout

  alias PerfectPaper.Email

  @doc "Invitation from one academic to a friend, with the referral link."
  @spec deliver_referral_invitation(String.t(), String.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_referral_invitation(invitee_email, referrer_name, referral_url) do
    assigns = %{referrer: referrer_name, url: referral_url}

    body = ~H"""
    <.document preview={"#{@referrer} thinks PerfectPaper will sharpen your next paper"}>
      <.eyebrow>An invitation from a colleague</.eyebrow>
      <p>
        <strong>{@referrer}</strong>
        uses PerfectPaper to polish their academic writing — and thought you'd like it too.
      </p>
      <p>
        PerfectPaper is an AI peer reviewer for papers: upload a draft and get measured,
        constructive feedback as comments you can accept, address, or set aside.
      </p>
      <.panel title="Your welcome gift">
        A free credit when you sign up — enough to review your first paper
      </.panel>
      <.button href={@url}>Claim your free review</.button>
      <p style="font-size:14px;color:#6b6259;">
        No pressure — if it's not for you, you can ignore this.
      </p>
    </.document>
    """

    text = """
    #{referrer_name} uses PerfectPaper to polish their academic writing — and
    thought you'd like it too.

    PerfectPaper is an AI peer reviewer for papers. Sign up with their link and
    you'll get a free credit — enough to review your first paper:
    #{referral_url}

    No pressure — if it's not for you, you can ignore this.
    """

    Email.deliver(invitee_email, "#{referrer_name} invited you to PerfectPaper", body, text)
  end

  @doc "Tells a referrer they earned a reward because someone they invited joined."
  @spec deliver_reward_earned(String.t(), pos_integer(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_reward_earned(referrer_email, reward_credits, url) do
    assigns = %{reward: reward_credits, url: url}

    body = ~H"""
    <.document preview="Your referral reward just landed">
      <.eyebrow>Reward earned</.eyebrow>
      <p>Wonderful news —</p>
      <p>
        Someone you referred just joined PerfectPaper, so we've added a reward to your account. Thank you for spreading the word.
      </p>
      <.panel title="Reward added">{@reward} credits</.panel>
      <p>Keep sharing PerfectPaper with colleagues — every friend who joins earns you more.</p>
      <.button href={@url}>See your rewards</.button>
    </.document>
    """

    text = """
    Wonderful news —

    Someone you referred just joined PerfectPaper, so we've added #{reward_credits}
    credits to your account. Thank you for spreading the word.

    See your rewards:
    #{url}
    """

    Email.deliver(referrer_email, "Your referral reward just landed", body, text)
  end
end
