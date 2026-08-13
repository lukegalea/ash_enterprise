defmodule AshEnterprise.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_enterprise,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader, Clarity.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules(),
      dialyzer: dialyzer(),
      releases: releases()
    ]
  end

  # Release configuration. See lib/ash_enterprise/release.ex for why migrations
  # run as a release command rather than a mix task.
  defp releases do
    [
      ash_enterprise: [
        include_executables_for: [:unix],
        # Bakes the ERTS into the release, so the runtime image needs no Erlang
        # installed and cannot drift from what the release was built against.
        include_erts: true,
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Configuration for `mix usage_rules.sync`, which gathers the `usage-rules.md`
  # files shipped inside our dependencies into AGENTS.md and generates Claude
  # skills from them.
  #
  # This is the single highest-leverage configuration in the repository for AI
  # agent accuracy: almost every ash_* package ships version-accurate guidance,
  # and the `~r/^ash_/` pattern picks up every one we add from here on without
  # further edits. An agent working from these rules writes current Ash rather
  # than whatever Ash looked like at its training cutoff.
  #
  # NOTE: usage_rules 1.0 REMOVED the old CLI flags (`--all`, `--inline`,
  # `--link-to-folder`). Everything is configured here now, and
  # `mix usage_rules.sync` takes no arguments. Tutorials showing those flags
  # predate 1.0 and will not work.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:ash, ~r/^ash_/, :phoenix, :igniter, :reactor, :elixir, :otp],
      skills: [
        location: ".claude/skills",
        package_skills: [:ash],
        build: [
          "ash-framework": [
            description:
              "Use when writing or modifying Ash resources, domains, actions, policies, or extensions.",
            usage_rules: [:ash, ~r/^ash_/]
          ],
          "phoenix-web": [
            description: "Use when working on LiveViews, controllers, components, or the router.",
            usage_rules: [:phoenix, :ash_phoenix]
          ]
        ]
      ]
    ]
  end

  # Dialyzer is deliberately advisory here -- see
  # docs/manifesto/07-what-we-do-not-have.md#4-dialyzer-certainty. Spark builds
  # resources through heavy macro expansion and there is no official guidance
  # for running Dialyzer against it, so the ignore file is seeded empirically.
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {AshEnterprise.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # NOTE: salad_ui is deliberately NOT a dependency. SaladUI 1.0 declares
      # `igniter` as a plain runtime dependency, which is incompatible with the
      # `only: [:dev, :test]` restriction we put on igniter below -- adding it
      # forces a code generation tool that writes files to disk into production
      # releases. SaladUI is shadcn-style (it copies component source into your
      # project), so the intended path is to vendor the components you want from
      # a scratch project into lib/ash_enterprise_web/components/.
      # See docs/adr/0006-design-system.md.
      #
      # {:salad_ui, "~> 1.0"},

      {:ash_credo, "~> 0.17", only: [:dev, :test], runtime: false},
      {:ash_cloak, "~> 0.3"},

      # Saga orchestration. Reactor arrives transitively via ash, but is declared
      # directly because we use it as an architectural component (Ash.Reactor for
      # transactional workflows with compensation) and because usage_rules only
      # gathers rules for direct dependencies.
      {:reactor, "~> 1.0"},

      # --- Declarative, agent-renderable UI (A2UI protocol) --------------------
      # Not published to hex, so this is a SHA-pinned git dependency. Tier 3 in
      # docs/manifesto/06-reversibility.md: confined to lib/ash_enterprise_web/a2ui/
      # so removing it is a deletion, not a refactor.
      {:ash_a2ui, github: "lukegalea/ash_a2ui"},

      # --- Observability -------------------------------------------------------
      # Ash.Tracer -> OpenTelemetry -> OTLP. opentelemetry_ash is thin (0.1.x);
      # expect to extend it. See docs/manifesto/07-what-we-do-not-have.md.
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_ash, "~> 0.1"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},

      # --- Static analysis -----------------------------------------------------
      # Dialyzer runs NON-BLOCKING in CI: there is no official guidance for
      # Dialyzer against Spark-generated code and it emits spurious warnings.
      # See docs/manifesto/07-what-we-do-not-have.md#4-dialyzer-certainty.
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:ex_money_sql, "~> 2.0"},
      {:hammer, "~> 7.0"},
      {:tidewave, "~> 0.8", only: [:dev]},
      {:ash_diagram, "~> 0.2"},
      {:clarity, "~> 0.6"},
      {:cinder, "~> 0.17"},
      {:ash_rate_limiter, "~> 1.0"},
      {:ash_money, "~> 0.2"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:ash_ai, "~> 0.8"},
      {:absinthe_phoenix, "~> 2.0"},
      {:oban, "~> 2.0"},
      {:open_api_spex, "~> 3.0"},
      {:ash_state_machine, "~> 0.2"},
      {:ash_events, "~> 0.7"},
      {:ash_paper_trail, "~> 0.6"},
      {:ash_archival, "~> 2.0"},
      {:ash_oban, "~> 0.8"},
      {:ash_graphql, "~> 1.0"},
      {:ash_json_api, "~> 1.0"},
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_admin, "~> 1.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ash_enterprise", "esbuild ash_enterprise"],
      "assets.deploy": [
        "tailwind ash_enterprise --minify",
        "esbuild ash_enterprise --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
