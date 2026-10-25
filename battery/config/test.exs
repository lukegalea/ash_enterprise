import Config

# ── Postgres ────────────────────────────────────────────────────────────────
# Standard PG* env vars; the keystone devenv exports PGPORT (the port the
# server actually listens on) and DB_USER/DB_PASSWORD. Defaults are the
# bare local box: 127.0.0.1:5432, user postgres, trust auth (no password).
pg_host = System.get_env("PGHOST", System.get_env("DB_HOST", "127.0.0.1"))
pg_port = String.to_integer(System.get_env("PGPORT", "5432"))
pg_user = System.get_env("PGUSER", System.get_env("DB_USER", "postgres"))
pg_password = System.get_env("PGPASSWORD", System.get_env("DB_PASSWORD", ""))

pg_common = [
  hostname: pg_host,
  port: pg_port,
  username: pg_user,
  password: pg_password,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  queue_target: 1000
]

db = "vendorpm_platform_battery_test"

config :ash_enterprise_battery, ecto_repos: [Battery.Repo]

config :ash_enterprise_battery, Battery.Repo, pg_common ++ [database: db]

# The evidence resources are package-owned and name AshEvidence.Repo; the
# host points that repo at its own database (residency is the host's
# concern). Same database as the battery's own tables.
config :ash_evidence,
  AshEvidence.Repo,
  pg_common ++ [database: db, types: AshEvidence.PostgrexTypes]

# ── ash_judgments: the stack the judge resolves profiles against ────────────
config :ash_judgments, region: :ca

config :ash_judgments, :profiles,
  [
    [
      name: :test_local,
      model: "test-model",
      base_url: {:system, "JUDGE_BASE_URL"},
      api_key: {:system, "JUDGE_API_KEY", "local"},
      residency: :in_cluster,
      region: :ca
    ]
  ]

# The battery's judgment ledger, materialised-facts table and banding ledger.
config :ash_judgments, :ledger, Battery.SystemOne.Judgment
config :ash_judgments, :facts, Battery.SystemOne.Fact
config :ash_judgments, :banding, Battery.SystemOne.Banding

# ── ash_bpmn: deterministic engine tests ────────────────────────────────────
# The runtime's Oban shim executes advance jobs inline instead of enqueueing.
config :ash_bpmn, oban_testing: :inline

# ── ash_discrete_business_events ────────────────────────────────────────────
# No trigger handler: the battery exercises the ledger → projector seam, not
# the BPMN trigger bridge.

config :logger, level: :warning
