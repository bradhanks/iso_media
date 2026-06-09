import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# A fixed admin email the LiveView tests log in as.
config :perfect_paper, :admin_emails, ["admin@perfectpaper.test"]

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :perfect_paper, PerfectPaper.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "perfect_paper_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :perfect_paper, PerfectPaperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "daeaXGWRoZw9roTOBO35tOlR6DHRWFrB6MXzzgLuM4YJ2wLY+HLNJYgRl3LGdgo3",
  server: false

# In test we don't send emails
config :perfect_paper, PerfectPaper.Mailer, adapter: Swoosh.Adapters.Test

# Social sign-in uses the stub adapter in tests (no real provider HTTP).
config :perfect_paper, :oauth_adapter, PerfectPaper.Accounts.OAuth.Stub

# Enterprise SSO: both protocols use the Stub adapter in tests (no real IdP).
config :perfect_paper, :sso_adapters,
  oidc: PerfectPaper.SSO.Stub,
  saml: PerfectPaper.SSO.Stub

# Webhooks: use the stub sender in tests — no real HTTP, records calls in the process dict.
config :perfect_paper, :webhook_sender, PerfectPaper.Webhooks.Sender.Stub

# Document importer: use the stub in tests — no real Pandoc binary required.
config :perfect_paper, :document_importer, PerfectPaper.Documents.Importer.Stub

# Don't start the credit PubSub subscribers in tests — the Ecto sandbox makes
# async DB writes from those processes impractical. Tests drive the synchronous
# cores (Credits.apply_event/2, Credits.notify_granted/1) directly.
config :perfect_paper, :start_credit_servers, false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban in test mode: jobs are enqueued to the DB but never executed automatically.
# Use assert_enqueued/perform_job from Oban.Testing for deterministic assertions.
config :perfect_paper, Oban, repo: PerfectPaper.Repo, testing: :manual
