defmodule PerfectPaper.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PerfectPaperWeb.Telemetry,
        PerfectPaper.Repo,
        {DNSCluster, query: Application.get_env(:perfect_paper, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PerfectPaper.PubSub},
        # Web-layer rate limiting for auth endpoints (ETS-backed Hammer store).
        {PerfectPaperWeb.RateLimit.Store, [clean_period: :timer.minutes(1)]},
        # Oban background job processing (queues: webhooks; testing: :manual in test env).
        {Oban, Application.fetch_env!(:perfect_paper, Oban)},
        # Task supervisor for fire-and-forget async work (e.g. IP risk-signal lookups).
        {Task.Supervisor, name: PerfectPaper.TaskSupervisor},
        # Circuit breaker for the Stripe HTTP boundary.
        PerfectPaper.Billing.CircuitBreaker
      ] ++ credit_event_servers() ++ [PerfectPaperWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PerfectPaper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The PubSub subscribers that run credit campaigns, email recipients, and grant
  # subscription allowances. Disabled in the test env (config :start_credit_servers),
  # where the Ecto sandbox makes async DB writes from these processes impractical;
  # the synchronous cores (Credits.apply_event/2, notify_granted/1,
  # grant_monthly_allowance_for_event/1) are exercised directly there.
  defp credit_event_servers do
    if Application.get_env(:perfect_paper, :start_credit_servers, true) do
      [
        PerfectPaper.Credits.GrantServer,
        PerfectPaper.Credits.NotifierServer,
        PerfectPaper.Credits.AllowanceServer,
        PerfectPaper.Credits.LowBalanceServer,
        PerfectPaper.Billing.SeatTrackerServer,
        PerfectPaper.Teams.JwksCache,
        PerfectPaper.Teams.NotifierServer
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PerfectPaperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
