import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/perfect_paper start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :perfect_paper, PerfectPaperWeb.Endpoint, server: true
end

config :perfect_paper, PerfectPaperWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Social sign-in (SSO). A provider is included only when BOTH its id and secret
# env vars are set, so a provider's button appears only once it is configured.
# Runs in all environments so dev picks up the vars too.
# Only providers with an Assent strategy in PerfectPaper.Accounts.OAuth.Assent
# belong here — listing one without a strategy makes its button appear but its
# sign-in fail. (ORCID is intentionally omitted until a strategy is added.)
oauth_providers =
  [
    {"google", "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"},
    {"github", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET"}
  ]
  |> Enum.reduce(%{}, fn {provider, id_var, secret_var}, acc ->
    case {System.get_env(id_var), System.get_env(secret_var)} do
      {id, secret} when is_binary(id) and is_binary(secret) and id != "" and secret != "" ->
        Map.put(acc, provider, client_id: id, client_secret: secret)

      _ ->
        acc
    end
  end)

config :perfect_paper, :oauth_providers, oauth_providers

# Language model adapter. The in-repo Stub is the compile-time default (see
# config/config.exs); here we switch to the live Anthropic adapter automatically
# whenever ANTHROPIC_API_KEY is set — so a writer gets real AI responses just by
# exporting the key, with no config edits. Never in :test, where the Stub keeps
# the suite hermetic and offline. The model is overridable via ANTHROPIC_MODEL.
anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")

if config_env() != :test and is_binary(anthropic_api_key) and anthropic_api_key != "" do
  config :perfect_paper, :llm_provider, PerfectPaper.Chatbot.LLM.Anthropic

  config :perfect_paper, PerfectPaper.Chatbot.LLM.Anthropic,
    api_key: anthropic_api_key,
    model: System.get_env("ANTHROPIC_MODEL") || "claude-haiku-4-5"
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :perfect_paper, PerfectPaper.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :perfect_paper,
         :admin_emails,
         System.get_env("ADMIN_EMAILS", "")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :perfect_paper, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :perfect_paper, PerfectPaperWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :perfect_paper, PerfectPaperWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :perfect_paper, PerfectPaperWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Mailer (Resend)
  #
  # Transactional email is delivered through Resend in production. The API key
  # must be provided via the environment and is never committed. The sender
  # address can be overridden with MAIL_FROM; the domain must be verified in
  # Resend for sends to succeed. The Req API client is configured in prod.exs.
  config :perfect_paper, PerfectPaper.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY")

  config :perfect_paper, :mail,
    from_name: "PerfectPaper",
    from_email: System.get_env("MAIL_FROM") || "no-reply@perfectpaper.org"
end
