defmodule AshEnterprise.Telemetry.LogExportTest do
  # async: false: installs the node-global OTLP log handler, and some tests switch the
  # primary translator's SASL setting.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.CrashFixtures
  alias AshEnterprise.Telemetry.CrashServer
  alias AshEnterprise.Telemetry.CrashStatem
  alias AshEnterprise.Telemetry.CrashWorker
  alias AshEnterprise.Telemetry.Logging
  alias AshEnterprise.Telemetry.QuietServer
  alias AshEnterprise.Telemetry.TestLogExporter

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest

  require Logger

  @endpoint AshEnterprise.Telemetry.TestEndpoint
  @handler :ash_enterprise_telemetry_otlp_logs

  # Once per module: the handler's exporter process outlives a quick remove and re-add.
  setup_all do
    :ok =
      Logging.add_otlp_handler(
        exporter: {TestLogExporter, %{}},
        scheduled_delay_ms: 20,
        level: :error
      )

    on_exit(fn -> :logger.remove_handler(@handler) end)
  end

  setup do
    Process.register(self(), :ash_telemetry_test_logs)
    :ok
  end

  defp sentinel(type), do: "SENTINEL-#{type}-#{System.unique_integer([:positive])}"

  # Turns on what `handle_sasl_reports: true` turns on: proc_lib crash and supervisor
  # reports, which the translator otherwise stops.
  defp with_sasl_reports do
    %{filters: filters} = :logger.get_primary_config()

    sasl =
      Enum.map(filters, fn
        {:logger_translator, {fun, config}} -> {:logger_translator, {fun, %{config | sasl: true}}}
        other -> other
      end)

    :ok = :logger.update_primary_config(%{filters: sasl})
    on_exit(fn -> :logger.update_primary_config(%{filters: filters}) end)
  end

  # Every record exported until one body contains each of `expected`.
  defp exported(expected, records \\ []) do
    if Enum.all?(expected, fn part -> Enum.any?(records, &(body(&1) =~ part)) end) do
      records
    else
      receive do
        {:otlp_logs, :empty} -> exported(expected, records)
        {:otlp_logs, proto} -> exported(expected, records ++ log_records(proto))
      after
        5_000 ->
          flunk("""
          no exported record contained all of #{inspect(expected)}; bodies:
          #{Enum.map_join(records, "\n---\n", &body/1)}
          """)
      end
    end
  end

  defp log_records(%{resource_logs: resource_logs}) do
    for %{scope_logs: scopes} <- resource_logs,
        %{log_records: records} <- scopes,
        record <- records,
        do: record
  end

  defp body(%{body: %{value: {:string_value, text}}}), do: text
  defp body(record), do: inspect(record.body)

  defp refute_leaks(records, sentinels) do
    exported = inspect(records, limit: :infinity, printable_limit: :infinity)

    for sentinel <- sentinels do
      refute exported =~ sentinel, "#{sentinel} reached an exported record:\n#{exported}"
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    reason
  end

  test "a GenServer crash exports neither its last message, its state nor frame arguments" do
    {message, state} = {sentinel("GENSERVER-MESSAGE"), sentinel("GENSERVER-STATE")}
    {:ok, pid} = GenServer.start(CrashServer, %{"state" => state})

    GenServer.cast(pid, {:crash, %{"secret" => message}})
    await_down(pid)

    records = exported(["GenServer #{inspect(pid)} terminating", "only_never/1"])
    refute_leaks(records, [message, state])
    assert Enum.any?(records, &(body(&1) =~ "FunctionClauseError"))
  end

  test "a gen_statem crash exports neither its event, its data nor the MatchError value" do
    {event, data} = {sentinel("STATEM-EVENT"), sentinel("STATEM-DATA")}
    {:ok, pid} = :gen_statem.start(CrashStatem, %{"data" => data}, [])

    :gen_statem.cast(pid, {:crash, event})
    await_down(pid)

    records = exported([":gen_statem #{inspect(pid)} terminating", "MatchError"])
    refute_leaks(records, [event, data])
  end

  test "a proc_lib crash report exports neither frame arguments nor the process's metadata" do
    with_sasl_reports()
    {argument, metadata} = {sentinel("PROC-LIB-ARG"), sentinel("PROC-LIB-META")}

    pid =
      :proc_lib.spawn(fn ->
        Logger.metadata(form: %{"secret" => metadata})
        CrashFixtures.clause(%{"secret" => argument})
      end)

    await_down(pid)

    records = exported(["Process #{inspect(pid)} terminating", "only_never/1"])
    refute_leaks(records, [argument, metadata])
  end

  test "a supervisor child report exports neither start arguments nor the exit reason's data" do
    with_sasl_reports()
    secret = sentinel("SUPERVISOR-CHILD")
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, pid} = DynamicSupervisor.start_child(supervisor, {CrashWorker, secret})
    GenServer.cast(pid, :stop)
    await_down(pid)

    records =
      exported(["of Supervisor #{inspect(supervisor)}", "terminated, ** (exit) :bad_state"])

    refute_leaks(records, [secret])
  end

  test "a Task crash exports neither the function's arguments nor frame arguments" do
    secret = sentinel("TASK-ARG")
    supervisor = start_supervised!(Task.Supervisor)

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, CrashFixtures, :clause, [%{"secret" => secret}])

    await_down(pid)

    records = exported(["Task #{inspect(pid)} started from", "only_never/1"])
    refute_leaks(records, [secret])
  end

  test "a server's unexpected message is not exported" do
    secret = sentinel("UNEXPECTED-MESSAGE")
    {:ok, pid} = GenServer.start(QuietServer, :state)

    send(pid, {:secret, secret})

    records = exported(["received unexpected message in handle_info/2"])
    refute_leaks(records, [secret])
    GenServer.stop(pid)
  end

  test "a Bandit request crash exports neither request values nor frame arguments" do
    secret = sentinel("BANDIT-QUERY")

    server =
      start_supervised!(
        {Bandit,
         plug: AshEnterprise.Telemetry.BanditProbePlug, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Req.get!("http://127.0.0.1:#{port}/form-clause?secret=#{secret}", retry: false)

    records = exported(["FunctionClauseError", "BanditProbePlug.only_never/1"])
    refute_leaks(records, [secret])
  end

  test "a Ranch-format request error exports neither the reason nor frame arguments" do
    secret = sentinel("RANCH-ARG")

    {reason, stacktrace} =
      try do
        CrashFixtures.clause(%{"secret" => secret})
      catch
        :error, reason -> {reason, __STACKTRACE__}
      end

    :logger.error(
      ~c"Ranch listener ~p, connection process ~p, stream ~p had its request process ~p exit with reason ~999999p and stacktrace ~999999p~n",
      [:http, self(), 1, self(), {reason, stacktrace}, stacktrace]
    )

    records = exported(["Ranch listener http"])
    refute_leaks(records, [secret])
  end

  test "an exit Phoenix formats after a crashed join exports no argument" do
    secret = sentinel("FORMAT-EXIT")
    {pid, ref} = spawn_monitor(fn -> CrashFixtures.clause(%{"secret" => secret}) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000

    Logger.error(fn -> Exception.format_exit(reason) end)

    records = exported(["an exception was raised", "Process #{inspect(pid)} raised an exception"])
    refute_leaks(records, [secret])
  end

  describe "a real LiveView" do
    setup do
      Process.flag(:trap_exit, true)
      {:ok, conn: build_conn()}
    end

    test "an event with no matching handle_event clause exports no form value", %{conn: conn} do
      secret = sentinel("FORM-VALUE")
      {:ok, view, _html} = live(conn, "/strict")

      catch_exit(render_click(view, "crash-form", %{"secret" => secret}))

      records = exported(["terminating", "handle_event/3"])
      refute_leaks(records, [secret, "strict-assign-secret"])
    end

    test "a crash inside an event handler exports neither form values nor assigns", %{conn: conn} do
      secret = sentinel("HANDLER-FORM-VALUE")
      {:ok, view, _html} = live(conn, "/live")

      catch_exit(render_click(view, "clause", %{"password" => secret}))

      records = exported(["terminating", "only_never/2"])
      refute_leaks(records, [secret, "assign-secret-value"])
    end
  end

  test "Sentry's logger handler reports from the scrubbed event, so its logs carry no crash data" do
    {message, state} = {sentinel("SENTRY-MESSAGE"), sentinel("SENTRY-STATE")}
    {id, filter} = AshEnterprise.Telemetry.SentryWiring.logger_filter()

    :ok =
      :logger.add_handler(:ash_telemetry_capture, AshEnterprise.Telemetry.CaptureLogHandler, %{
        config: %{pid: self()},
        level: :error,
        filters: [{id, filter}]
      })

    on_exit(fn -> :logger.remove_handler(:ash_telemetry_capture) end)

    {:ok, pid} = GenServer.start(CrashServer, %{"state" => state})
    GenServer.cast(pid, {:crash, %{"secret" => message}})
    await_down(pid)

    assert_receive {:log_event, %{meta: %{crash_reason: {%FunctionClauseError{}, _}}} = event},
                   5_000

    attributes = Map.drop(event.meta, [:time, :gl, :report_cb, :domain, :mfa, :file, :line, :pid])
    log = Sentry.LogEvent.from_logger_event(event, attributes)

    sent = AshEnterprise.Telemetry.SentryWiring.before_send_log(log)
    refute_leaks([sent], [message, state])
    assert sent.body =~ "GenServer #{inspect(pid)} terminating"
    assert sent.body =~ "only_never/1"
  end

  test "setup gives the Sentry handler the scrub filter" do
    :ok = AshEnterprise.Telemetry.SentryWiring.add_logger_handler()
    on_exit(fn -> :logger.remove_handler(:sentry_handler) end)

    {:ok, %{filters: filters}} = :logger.get_handler_config(:sentry_handler)
    assert Keyword.has_key?(filters, :ash_enterprise_telemetry_export_scrub)
  end

  test "the export filter is installed with the handler" do
    {:ok, %{filters: filters}} = :logger.get_handler_config(@handler)
    assert Keyword.has_key?(filters, :ash_enterprise_telemetry_export_scrub)
  end
end
