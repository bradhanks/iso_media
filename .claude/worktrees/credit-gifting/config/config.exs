# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :perfect_paper, :scopes,
  user: [
    default: true,
    module: PerfectPaper.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: PerfectPaper.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :perfect_paper,
  ecto_repos: [PerfectPaper.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Side-effecting contexts run behind config-selected behaviour adapters.
# Defaults are the in-repo stubs; swap per-env for real vendors later.
config :perfect_paper, :billing_provider, PerfectPaper.Billing.StubAdapter
config :perfect_paper, :llm_provider, PerfectPaper.Chatbot.LLM.Stub
config :perfect_paper, :storage_provider, PerfectPaper.Documents.Storage.Local
config :perfect_paper, :webhook_sender, PerfectPaper.Webhooks.Sender.Req
config :perfect_paper, :pricing_risk_provider, PerfectPaper.Billing.RiskSignals.Stub
config :perfect_paper, :document_importer, PerfectPaper.Documents.Importer.Panpipe
config :perfect_paper, :teams_token_verifier, PerfectPaper.Teams.TokenVerifier.Stub

# Stripe credentials (real values come from runtime/env in prod — see runtime.exs).
# The billing_provider stays the stub by default; set it to StripeAdapter in the
# env that has real keys. price_ids maps {plan|pack, cadence} → Stripe price id.
config :perfect_paper, :stripe,
  api_key: nil,
  webhook_secret: nil,
  publishable_key: nil,
  price_ids: %{},
  # :hosted (redirect to Stripe) or :embedded (Stripe Checkout iframe mounted in-app
  # via the StripeEmbeddedCheckout JS hook + the dahlia Stripe.js).
  checkout_ui: :hosted

config :perfect_paper, :teams_bot, PerfectPaper.Teams.Bot.Stub

# MFA adapters per factor type (anti-corruption layer). Stubs until implemented — see Spec 6.
config :perfect_paper, :mfa_adapters,
  totp: PerfectPaper.Accounts.MFA.TOTP,
  webauthn: PerfectPaper.Accounts.MFA.WebAuthn

# OAuth / social sign-in. The adapter is the only seam that talks to providers.
config :perfect_paper, :oauth_adapter, PerfectPaper.Accounts.OAuth.Assent
config :perfect_paper, :oauth_providers, %{}

# Enterprise SSO. Per-protocol adapters (real ones land in Tasks 3 + 7).
# Naming them here is fine — they're atoms, not invoked until those tasks ship.
config :perfect_paper, :sso_adapters,
  oidc: PerfectPaper.SSO.OIDC,
  saml: PerfectPaper.SSO.SAML

# Operator allowlist for the /admin surface. Overridden per-environment;
# populated from ADMIN_EMAILS in production (see config/runtime.exs).
config :perfect_paper, :admin_emails, []

# Configure the endpoint
config :perfect_paper, PerfectPaperWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PerfectPaperWeb.ErrorHTML, json: PerfectPaperWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PerfectPaper.PubSub,
  live_view: [signing_salt: "0I/E+hBI"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :perfect_paper, PerfectPaper.Mailer, adapter: Swoosh.Adapters.Local

# Default sender identity for transactional email. Overridable at runtime
# (see config/runtime.exs) via the MAIL_FROM environment variable in prod.
config :perfect_paper, :mail,
  from_name: "PerfectPaper",
  from_email: "no-reply@perfectpaper.org"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  perfect_paper: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  perfect_paper: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# i18n — English is the source language; the 11 other locale catalogs live under
# priv/gettext/<locale>/LC_MESSAGES (see PerfectPaper.Localization).
config :gettext, :default_locale, "en"
# Custom pluralizer handles BCP 47 hyphenated codes (en-GB, fr-CA, es-MX) by
# stripping the territory and delegating to the base language's plural rules.
config :gettext, :plural_forms, PerfectPaperWeb.GettextPlural

# Oban background job processing — queues and pruner configured here;
# test.exs overrides with testing: :manual so jobs are never auto-run in tests.
config :perfect_paper, Oban,
  repo: PerfectPaper.Repo,
  queues: [
    webhooks: 10,
    documents: 10,
    reviews: 10,
    teams_notifier: 5,
    maintenance: 5,
    notifications: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Cron is required for scheduled retention jobs to fire at all; without it the
    # pricing-audit PII would grow unbounded. Runs the anonymizer daily at 03:00.
    {Oban.Plugins.Cron, crontab: [{"0 3 * * *", PerfectPaper.Billing.PricingAuditAnonymizer}]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
