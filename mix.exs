defmodule HgsSurrealdbSdk.MixProject do
  use Mix.Project

  def project do
    [
      app: :hgs_surrealdb_sdk,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {HgsSurrealdbSdk.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:zoi, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.5.1"},
      {:igniter, "~> 0.5", optional: true},
      {:bandit, "~> 1.0", only: :dev},
      {:tidewave, "~> 0.5", only: [:dev]}
    ]
  end

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4001) end)'"
    ]
  end
end
