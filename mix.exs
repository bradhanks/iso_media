defmodule IsoMedia.MixProject do
  use Mix.Project

  def project do
    [
      app: :iso_media,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
