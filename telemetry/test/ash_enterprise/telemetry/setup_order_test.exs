defmodule AshEnterprise.Telemetry.SetupOrderTest do
  use ExUnit.Case, async: true

  # Telemetry runs handlers in attach order, so the order of this list is the
  # order the code depends on.

  defp handler_ids(event) do
    event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
  end

  defp index_of(ids, id) do
    Enum.find_index(ids, &(&1 == id)) || flunk("#{inspect(id)} is not attached")
  end

  @browser AshEnterprise.Telemetry.BrowserContext
  @oban_context AshEnterprise.Telemetry.ObanContext

  test "the correlation handler runs before the Phoenix span opens on start" do
    ids = handler_ids([:phoenix, :live_view, :handle_event, :start])

    before = index_of(ids, {@browser, :before})
    span = index_of(ids, {AshEnterprise.Telemetry.PhoenixSpans, :span})
    after_span = index_of(ids, {@browser, :after})

    assert before < span
    assert span < after_span
  end

  test "the detach handler runs after the Phoenix span closes, on stop and exception" do
    for suffix <- [:stop, :exception],
        event <- [
          [:phoenix, :live_view, :handle_event, suffix],
          [:phoenix, :live_component, :handle_event, suffix]
        ] do
      ids = handler_ids(event)

      assert index_of(ids, {AshEnterprise.Telemetry.PhoenixSpans, :span}) <
               index_of(ids, {@browser, :after})
    end
  end

  test "the Oban correlation handler runs before the job span opens" do
    ids = handler_ids([:oban, :job, :start])

    assert index_of(ids, {@oban_context, :start}) <
             index_of(ids, {@oban_context, :job_span})

    refute "Elixir.OpentelemetryOban.JobHandler.job_start" in ids
  end

  test "the Oban restore handler runs after the job span closes" do
    for {suffix, handler} <- [
          {:stop, "Elixir.OpentelemetryOban.JobHandler.job_stop"},
          {:exception, {@oban_context, :job_exception}}
        ] do
      ids = handler_ids([:oban, :job, suffix])
      assert index_of(ids, handler) < index_of(ids, {@oban_context, :stop})
    end

    refute "Elixir.OpentelemetryOban.JobHandler.job_exception" in handler_ids([
             :oban,
             :job,
             :exception
           ])
  end

  test "both HTTP layers are attached" do
    # They listen to different events, so attach order is not observable here;
    # `setup/1` attaches Bandit first and the live-stack check reads the joined span.
    assert handler_ids([:bandit, :request, :start]) != []

    assert {OpentelemetryPhoenix, :router_dispatch_start} in handler_ids([
             :phoenix,
             :router_dispatch,
             :start
           ])
  end

  test "setup is idempotent" do
    assert :ok =
             AshEnterprise.Telemetry.setup(
               otp_app: :ash_enterprise_telemetry,
               browser_context: true,
               event_attributes: {AshEnterprise.Telemetry.TestEventAttributes, :resolve, []},
               db_statement: :enabled,
               repo_prefixes: [[:ash_enterprise, :telemetry, :test_repo]]
             )

    ids = handler_ids([:phoenix, :live_view, :handle_event, :start])
    assert Enum.count(ids, &(&1 == {@browser, :before})) == 1
  end

  test "the Ash tracer's trace types are explicit" do
    assert Application.get_env(:opentelemetry_ash, :trace_types) == [:custom, :action, :flow]
  end
end
