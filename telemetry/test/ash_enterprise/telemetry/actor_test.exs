defmodule AshEnterprise.Telemetry.ActorTest do
  # `enduser_name?` is application env.
  use ExUnit.Case, async: false

  alias AshEnterprise.Telemetry.Actor
  alias AshEnterprise.Telemetry.TaskContext
  alias AshEnterprise.Telemetry.TestRepo
  alias AshEnterprise.Telemetry.TestWorker
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  @actor [
    id: "u-1",
    role: :manager,
    name: "pat@example.test",
    tenant_id: "t-1",
    tenant_name: "Acme"
  ]

  setup do
    previous = Application.get_env(:ash_enterprise_telemetry, :enduser_name?)

    on_exit(fn ->
      Application.put_env(:ash_enterprise_telemetry, :enduser_name?, previous)
    end)

    Actor.clear()
    :ok
  end

  test "put stamps the open span and every span started after it" do
    key = test_key!()

    Tracer.with_span "request" do
      Actor.put(@actor)
      Tracer.with_span("child", do: :ok)
    end

    for name <- ["request", "child"] do
      span = span_named(key, name)
      assert attr(span, :"enduser.id") == "u-1"
      assert attr(span, :"enduser.role") == "manager"
      assert attr(span, :"app.tenant.id") == "t-1"
      assert attr(span, :"app.tenant.name") == "Acme"
      refute attr(span, :"enduser.name")
    end
  end

  test "the name is recorded only when turned on" do
    Application.put_env(:ash_enterprise_telemetry, :enduser_name?, true)
    key = test_key!()

    Tracer.with_span "named" do
      Actor.put(@actor)
    end

    assert attr(span_named(key, "named"), :"enduser.name") == "pat@example.test"
  end

  test "restore keeps known keys only and drops the name when off" do
    Actor.restore(%{
      "enduser.id" => "u-2",
      "enduser.name" => "x",
      "ash.actor" => "forged",
      "app.tenant.id" => 5
    })

    assert Actor.current() == %{"enduser.id": "u-2"}
  end

  test "the meta tag content is the attributes as JSON" do
    assert Actor.meta_content() == ""
    Actor.put(id: "u-3", tenant_id: "t-3")

    assert Jason.decode!(Actor.meta_content()) == %{
             "enduser.id" => "u-3",
             "app.tenant.id" => "t-3"
           }
  end

  test "a task carries the actor and the caller's actor is restored after" do
    key = test_key!()
    Actor.put(@actor)
    captured = TaskContext.capture()
    Actor.clear()

    task =
      Task.async(fn ->
        TaskContext.run(captured, fn ->
          AshEnterprise.Telemetry.TestKey.put(key)
          Tracer.with_span("in.task", do: :ok)
        end)

        Actor.current()
      end)

    assert Task.await(task) == %{}
    assert attr(span_named(key, "in.task"), :"enduser.id") == "u-1"
  end

  describe "jobs" do
    setup do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
      :ok
    end

    test "a job enqueued by an actor runs as that actor" do
      key = test_key!()
      ref = "ref-#{System.unique_integer([:positive])}"
      args = %{"pid" => self() |> :erlang.pid_to_list() |> to_string(), "ref" => ref}

      Actor.put(@actor)
      job = Oban.insert!(TestWorker.new(args))
      Actor.clear()

      assert job.meta["enduser"] == %{
               "enduser.id" => "u-1",
               "enduser.role" => "manager",
               "app.tenant.id" => "t-1",
               "app.tenant.name" => "Acme"
             }

      Oban.drain_queue(queue: :default)
      assert_received {:job_ran, ^ref, _correlation}

      assert attr(span_named(key, "inside.job"), :"enduser.id") == "u-1"
      assert Actor.current() == %{}
    end
  end
end
