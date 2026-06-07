defmodule IsoMedia.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bradhanks/iso_media"

  def project do
    [
      app: :iso_media,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ISOMedia",
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      # :xmerl is OTP stdlib, loaded only in test to re-parse generated DASH MPDs for
      # well-formedness; the library itself stays zero-runtime-dependency.
      extra_applications: extra_applications(Mix.env())
    ]
  end

  defp extra_applications(:test), do: [:logger, :xmerl]
  defp extra_applications(_), do: [:logger]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Lossless ISOBMFF (MP4/MOV/M4A/HEIF) box surgery in pure Elixir: parse any " <>
      "ISO Base Media file into a byte-exact tree of boxes, then navigate, edit, " <>
      "extract, trim, concatenate, fragment, and re-serialize it."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
