alias AshEnterprise.Telemetry.TestRepo

config = Application.fetch_env!(:ash_enterprise_telemetry, TestRepo)

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)

_ =
  case TestRepo.__adapter__().storage_up(config) do
    :ok -> :ok
    {:error, :already_up} -> :ok
    {:error, reason} -> raise "could not create the test database: #{inspect(reason)}"
  end

{:ok, _} = TestRepo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)

# Oban's own schema; the suite shares one migrated database.
Ecto.Migrator.run(
  TestRepo,
  [{1, AshEnterprise.Telemetry.TestMigration}],
  :up,
  all: true,
  log: false
)

:ok = TestRepo.stop()

{:ok, _} = TestRepo.start_link()

{:ok, _} =
  AshEnterprise.Telemetry.TestEndpoint.start_link()

{:ok, _} =
  Oban.start_link(
    name: Oban,
    repo: TestRepo,
    testing: :manual,
    engine: AshEnterprise.Telemetry.ObanEngine,
    queues: false,
    plugins: false
  )

AshEnterprise.Telemetry.setup(
  otp_app: :ash_enterprise_telemetry,
  repo_prefixes: [[:ash_enterprise, :telemetry, :test_repo]],
  browser_context: true,
  event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []},
  db_statement: :enabled
)

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

ExUnit.start(capture_log: true)
