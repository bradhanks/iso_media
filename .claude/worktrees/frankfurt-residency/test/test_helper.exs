ExUnit.configure(exclude: [:pandoc])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(PerfectPaper.Repo, :manual)
