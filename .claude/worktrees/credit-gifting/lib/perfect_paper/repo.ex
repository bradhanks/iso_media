defmodule PerfectPaper.Repo do
  use Ecto.Repo,
    otp_app: :perfect_paper,
    adapter: Ecto.Adapters.Postgres
end
