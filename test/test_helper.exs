e2e? = System.get_env("E2E") == "1"

# `AshBrowserTests.Reporter` records each test's outcome so
# `mix ash_browser_tests.report` can join it to the screenshot and trace that
# test left behind — those filenames carry no outcome of their own. Only for the
# browser tier: a plain `mix test` has no media for it to describe, and would
# leave a stale results file for the report task to believe.
if e2e? do
  ExUnit.start(formatters: [ExUnit.CLIFormatter, AshBrowserTests.Reporter])
else
  ExUnit.start()
end

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
  # `:backup_drill` dumps and restores the test database, which needs pg_dump no older than
  # the server; CI runs it in the backup-restore-drill job with `mix test --only backup_drill`.
  # `:scale` seeds 50,000 rows to hold the page budget; CI runs it as its own job
  # with `mix test --only scale` (test/ash_enterprise/scale/).
  # `:e2e` is the browser tier (test/e2e), which needs a served endpoint and a
  # Chromium. Excluded unless `mix test.browser` asked for it, so `mix test`
  # stays what it was.
  ExUnit.configure(
    exclude:
      [:instrument_contract, :in_zone_live, :durability, :scale, :backup_drill] ++
        if(e2e?, do: [], else: [:e2e])
  )

  Ecto.Adapters.SQL.Sandbox.mode(AshEnterprise.Repo, :manual)
  # The evidence substrate's repo rides the same test database (AST-152); its
  # sandbox follows the host's.
  Ecto.Adapters.SQL.Sandbox.mode(AshEvidence.Repo, :manual)

  # Starts the Playwright supervisor, points PhoenixTest at the endpoint and
  # attaches the sandbox hook. Only for the tier that needs a browser.
  if e2e? do
    AshBrowserTests.start!(endpoint: AshEnterpriseWeb.Endpoint)
  end
end
