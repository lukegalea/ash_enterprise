ExUnit.start()

if AshEnterprise.Durability.enabled?() do
  # The durability tier: no sandbox, a dedicated database, a real Oban. It runs only the
  # `:durability` tests and drops its database when the suite ends. See
  # docs/DURABILITY-TESTS.md.
  AshEnterprise.Durability.configure_suite!()
else
  # `:instrument_contract` runs only under `mix test --only instrument_contract`
  # (the dual contract test needs a reachable instrument); include wins over
  # exclude in ExUnit, so the --only flag still selects it. Same posture as
  # ash_judgments' own helper.
  # `:in_zone_live` asks the real in-zone runtime (synthetic data only); run it
  # with `--only in_zone_live` and S1_GEN_BASE_URL / S1_GEN_MODEL set.
  # `:durability` runs only under `mix test.durability`, which switches the
  # whole run off the sandbox (docs/DURABILITY-TESTS.md).
  ExUnit.configure(exclude: [:instrument_contract, :in_zone_live, :durability])

  Ecto.Adapters.SQL.Sandbox.mode(AshEnterprise.Repo, :manual)
  # The evidence substrate's repo rides the same test database (AST-152); its
  # sandbox follows the host's.
  Ecto.Adapters.SQL.Sandbox.mode(AshEvidence.Repo, :manual)
end
