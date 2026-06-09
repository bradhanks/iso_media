defmodule PerfectPaperWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PerfectPaperWeb, :html

  embed_templates "page_html/*"

  @doc false
  # Pricing cards render whether `Billing.Prices` yields the rich `plan_map`
  # (`:name` / `:price_label`) or the legacy product map (`:plan` /
  # `:price_cents`), so the public home page never 500s if the catalogue shape
  # changes underneath it.
  def plan_name(%{name: name}) when is_binary(name), do: name
  def plan_name(%{plan: plan}), do: plan |> to_string() |> String.capitalize()

  @doc false
  def plan_price(%{price_label: label}) when is_binary(label), do: label

  def plan_price(%{price_cents: _} = product),
    do: PerfectPaper.Billing.Prices.price_label(product)

  @doc false
  # Static FAQ content for the home page's #faq anchor section.
  def faqs do
    [
      {gettext("How long does a review take?"),
       gettext("Most reviews complete in 10–30 minutes. We email you the moment yours is ready.")},
      {gettext("What file types can I upload?"),
       gettext("Word documents (.docx) up to 25 MB. Support for more formats is on the way.")},
      {gettext("Can I export my reviewed manuscript?"),
       gettext(
         "Yes. Download your manuscript and its feedback as Word (.docx), Markdown, or HTML."
       )},
      {gettext("Is my manuscript kept private?"),
       gettext("Yes. Your content is encrypted, never shared, and never used to train models.")},
      {gettext("How is this different from a grammar checker?"),
       gettext(
         "PerfectPaper reviews substance — methods, evidence, logic, and consistency — the way a referee would, not just spelling and style."
       )}
    ]
  end

  @doc false
  # Placeholder testimonials for the public /testimonials page. Replace `quote`
  # text and swap `avatar_src` for real headshots when available.
  def testimonials do
    [
      %{
        quote:
          gettext(
            "PerfectPaper turned a dreaded revision cycle into an afternoon. It flagged an unsupported claim in my methods that two human reviewers had missed."
          ),
        name: "Dr. Jordan Avery",
        title: gettext("Associate Professor of Epidemiology"),
        institution: gettext("University of Utah"),
        avatar_src: "/images/avatar-placeholder.svg"
      },
      %{
        quote:
          gettext(
            "The comments read like a thoughtful colleague's, not a grammar checker's. Every note pointed to the exact passage and explained why it mattered."
          ),
        name: "Dr. Priya Nair",
        title: gettext("Postdoctoral Research Fellow"),
        institution: gettext("Huntsman Cancer Institute"),
        avatar_src: "/images/avatar-placeholder.svg"
      },
      %{
        quote:
          gettext(
            "I sent my first-author manuscript through before submission and walked in far more confident. Worth it for the consistency checks alone."
          ),
        name: "Marcus Bennett",
        title: gettext("PhD Candidate, Population Health"),
        institution: gettext("American Cancer Society Fellow"),
        avatar_src: "/images/avatar-placeholder.svg"
      }
    ]
  end

  @doc false
  # Anchored sections for the /enterprise hub. Each describes shipped capability,
  # framed honestly; `support` is a sales offering, not a built feature.
  def enterprise_areas do
    [
      %{
        id: "security",
        icon: "hero-shield-check",
        title: gettext("Security"),
        blurb:
          gettext(
            "Your manuscripts are encrypted in transit and at rest and are never used to train models."
          ),
        points: [
          gettext("Encryption in transit and at rest"),
          gettext("Content never used for model training"),
          gettext("Input sanitization on every upload")
        ],
        link_label: gettext("Read the full security page"),
        link_href: "/enterprise/security"
      },
      %{
        id: "teams",
        icon: "hero-users",
        title: gettext("Teams & organizations"),
        blurb:
          gettext(
            "Bring your lab or department together with shared organizations, roles, and credits."
          ),
        points: [
          gettext("Organizations with member roles"),
          gettext("Groups and per-project access"),
          gettext("Invitations and a shared credit pool")
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "access",
        icon: "hero-key",
        title: gettext("Access & identity"),
        blurb:
          gettext(
            "Sign in the way your institution already does, and control exactly who sees what."
          ),
        points: [
          gettext("Single sign-on (SSO)"),
          gettext("Organization-enforced multi-factor authentication"),
          gettext("Granular, scoped access grants")
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "developers",
        icon: "hero-command-line",
        title: gettext("Developer platform"),
        blurb: gettext("Automate reviews and stream events into your own systems."),
        points: [
          gettext("API keys and a REST API"),
          gettext("Organization-scoped webhooks, HMAC-signed"),
          gettext("Delivery log with replay")
        ],
        link_label: gettext("API docs"),
        link_href: "/api/docs"
      },
      %{
        id: "compliance",
        icon: "hero-document-check",
        title: gettext("Compliance & data"),
        blurb:
          gettext("Clear data handling and a compliance roadmap you can share with your IT team."),
        points: [
          gettext("Configurable retention and deletion"),
          gettext("Documented subprocessors and data residency"),
          gettext("Pursuing SOC 2 and ISO 27001 certification")
        ],
        link_label: nil,
        link_href: nil
      },
      %{
        id: "support",
        icon: "hero-lifebuoy",
        title: gettext("Support & SLAs"),
        blurb:
          gettext(
            "Dedicated support, onboarding help, and service-level agreements are available on enterprise plans."
          ),
        points: [
          gettext("Dedicated support contact"),
          gettext("Onboarding and IT help-desk resources"),
          gettext("Service-level agreements (SLAs)")
        ],
        link_label: gettext("Talk to sales"),
        link_href: "/contact"
      }
    ]
  end

  @doc false
  # In-depth sections for the /enterprise/security page.
  def enterprise_security_details do
    [
      %{
        title: gettext("Encryption"),
        body:
          gettext(
            "Your manuscripts are encrypted in transit (TLS) and at rest. Access is controlled and scoped so only you and the collaborators you choose can read a review."
          )
      },
      %{
        title: gettext("Never used for training"),
        body:
          gettext(
            "Your papers are yours. Nothing you upload is ever used as training data, and your content is not shared with third parties for that purpose."
          )
      },
      %{
        title: gettext("Input sanitization"),
        body:
          gettext(
            "Uploaded text is run through Unicode sanitization before processing, removing hidden and malformed characters that could otherwise interfere with a review."
          )
      },
      %{
        title: gettext("Retention and deletion"),
        body:
          gettext(
            "We keep your documents only as long as needed to produce your review. You can delete a review and its source document at any time."
          )
      },
      %{
        title: gettext("Compliance"),
        body:
          gettext(
            "Pursuing SOC 2 and ISO 27001 certification. Our data handling, subprocessors, and security posture are documented and available for your IT and procurement teams."
          )
      }
    ]
  end
end
