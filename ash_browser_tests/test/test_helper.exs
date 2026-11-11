alias AshBrowserTests.Fixture.Endpoint
alias AshBrowserTests.Fixture.Migration
alias AshBrowserTests.Fixture.Repo

config = Application.fetch_env!(:ash_browser_tests, Repo)

{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:ash_postgres)

_ =
  case Repo.__adapter__().storage_up(config) do
    :ok -> :ok
    {:error, :already_up} -> :ok
    {:error, reason} -> raise "could not create the test database: #{inspect(reason)}"
  end

{:ok, _} = Repo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)
Ecto.Migrator.run(Repo, [{1, Migration}], :up, all: true, log: false)
:ok = GenServer.stop(Repo)

{:ok, _} = Repo.start_link()

endpoint_config = Application.fetch_env!(:ash_browser_tests, Endpoint)
port = AshBrowserTests.free_port()

Application.put_env(
  :ash_browser_tests,
  Endpoint,
  Keyword.merge(endpoint_config,
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "127.0.0.1", port: port]
  )
)

{:ok, _} =
  Phoenix.PubSub.Supervisor.start_link(
    name: AshBrowserTests.Fixture.PubSub,
    adapter: Phoenix.PubSub.PG2
  )

{:ok, _} = Endpoint.start_link()

{:ok, _} =
  Oban.start_link(
    name: Oban,
    repo: Repo,
    testing: :manual,
    engine: AshEnterprise.Telemetry.ObanEngine,
    queues: false,
    plugins: false
  )

AshEnterprise.Telemetry.setup(
  otp_app: :ash_browser_tests,
  repo_prefixes: [[:ash_browser_tests, :fixture, :repo]],
  browser_context: true,
  db_statement: :enabled
)

AshBrowserTests.start!(endpoint: Endpoint)

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

ExUnit.start(capture_log: true, exclude: [:live_backends])
