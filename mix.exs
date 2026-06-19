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
      package: package(),
      docs: docs(),
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
      {:ex_doc, "~> 0.36", only: :dev, runtime: false},
      {:bandit, "~> 1.0", only: :dev},
      {:tidewave, "~> 0.5", only: [:dev]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/michaelwa/hgs_surrealdb_sdk",
        "SurrealDB" => "https://surrealdb.com/docs/surrealdb",
        "Zoi" => "https://hexdocs.pm/zoi"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/michaelwa/hgs_surrealdb_sdk",
      extras: [
        "README.md",
        "docs/getting-started.md",
        "docs/installing-surrealdb.md",
        "docs/schema-and-repo.md",
        "docs/transports-and-live-queries.md",
        "docs/migrations.md",
        "docs/telemetry.md",
        "docs/troubleshooting.md"
      ],
      groups_for_extras: [
        Guides: [
          "docs/getting-started.md",
          "docs/installing-surrealdb.md",
          "docs/schema-and-repo.md",
          "docs/transports-and-live-queries.md",
          "docs/migrations.md",
          "docs/telemetry.md",
          "docs/troubleshooting.md"
        ]
      ],
      skip_undefined_reference_warnings_on: [
        "SurrealDB",
        "SurrealDB.Migrations",
        "SurrealDB.Repo",
        "SurrealDB.Repo.FilterBuilder",
        "SurrealDB.Telemetry"
      ]
    ]
  end

  defp aliases do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4001) end)'"
    ]
  end
end
