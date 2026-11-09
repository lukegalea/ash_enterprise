defmodule AshEnterprise.Telemetry.ObanTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Telemetry.Correlation
  alias AshEnterprise.Telemetry.FailingWorker
  alias AshEnterprise.Telemetry.ObanContext
  alias AshEnterprise.Telemetry.TestRepo
  alias AshEnterprise.Telemetry.TestWorker
  alias OpenTelemetry.Tracer

  import AshEnterprise.Telemetry.TraceHelpers

  require OpenTelemetry.Tracer

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  defp worker_args(ref) do
    %{"pid" => self() |> :erlang.pid_to_list() |> to_string(), "ref" => ref}
  end

  defp new_job(meta \\ %{}, opts \\ []) do
    ref = "ref-#{System.unique_integer([:positive])}"
    {TestWorker.new(worker_args(ref), [meta: meta] ++ opts), ref}
  end

  defp drain, do: Oban.drain_queue(queue: :default)

  describe "the producer span and stamped meta" do
    test "an insert opens a send span and stamps traceparent and correlation_id" do
      key = test_key!()
      id = Correlation.start_new()
      {changeset, _ref} = new_job()

      job =
        Tracer.with_span "request.root" do
          {:ok, job} = Oban.insert(changeset)
          job
        end

      send_span = span_named(key, "send default")
      assert send_span.kind == :producer
      assert attr(send_span, :"messaging.system") == "oban"
      assert attr(send_span, :"messaging.destination.name") == "default"
      assert attr(send_span, :"oban.job.worker") =~ "TestWorker"
      assert attr(send_span, "ash.correlation_id") == id

      assert job.meta["correlation_id"] == id
      assert job.meta["traceparent"] =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/

      trace_hex =
        send_span.trace_id
        |> Integer.to_string(16)
        |> String.downcase()
        |> String.pad_leading(32, "0")

      assert String.contains?(job.meta["traceparent"], trace_hex)

      span_hex =
        send_span.span_id
        |> Integer.to_string(16)
        |> String.downcase()
        |> String.pad_leading(16, "0")

      assert String.contains?(job.meta["traceparent"], span_hex)
    end

    test "the job span is a linked root in a new trace, with the correlation restored" do
      key = test_key!()
      id = Correlation.start_new()
      {changeset, ref} = new_job()

      Tracer.with_span "request.root" do
        Oban.insert!(changeset)
      end

      send_span = span_named(key, "send default")
      Correlation.clear()
      drain()

      assert_received {:job_ran, ^ref, ^id}

      inner = span_named(key, "inside.job")
      job_span = Enum.find(spans(key), &(&1.span_id == inner.parent_span_id))

      assert job_span.name == "process default"
      assert job_span.kind == :consumer
      assert job_span.trace_id != send_span.trace_id
      assert attr(job_span, "ash.correlation_id") == id
      assert [%{span_id: linked, trace_id: linked_trace}] = job_span.links
      assert linked == send_span.span_id
      assert linked_trace == send_span.trace_id
    end

    test "existing meta is preserved" do
      test_key!()
      Correlation.start_new()
      {changeset, _ref} = new_job(%{"tenant" => "acme", custom: 1})

      {:ok, job} = Oban.insert(changeset)

      assert job.meta["tenant"] == "acme"
      assert job.meta[:custom] == 1
      assert job.meta["traceparent"]
    end

    test "an existing traceparent and correlation id are kept" do
      key = test_key!()
      Correlation.start_new()
      {changeset, _ref} = new_job(%{"traceparent" => "kept", "correlation_id" => "original"})

      {:ok, job} = Oban.insert(changeset)

      assert job.meta["traceparent"] == "kept"
      assert job.meta["correlation_id"] == "original"
      refute span_named(key, "send default")
    end

    test "an atom-keyed correlation id is not duplicated under a string key" do
      test_key!()
      Correlation.start_new()
      {changeset, _ref} = new_job(%{correlation_id: "original"})

      {:ok, job} = Oban.insert(changeset)

      assert job.meta[:correlation_id] == "original"
      refute Map.has_key?(job.meta, "correlation_id")
    end

    test "an existing traceparent still gets the correlation id" do
      test_key!()
      id = Correlation.start_new()
      {changeset, _ref} = new_job(%{"traceparent" => "kept"})

      {:ok, job} = Oban.insert(changeset)

      assert job.meta["traceparent"] == "kept"
      assert job.meta["correlation_id"] == id
    end

    test "a stale correlation id already in meta beats the current one" do
      test_key!()
      Correlation.start_new()
      {changeset, _ref} = new_job(%{"correlation_id" => "original"})

      {:ok, job} = Oban.insert(changeset)

      assert job.meta["correlation_id"] == "original"
      assert job.meta["traceparent"]
    end

    test "no correlation in scope means no correlation_id key" do
      test_key!()
      {changeset, _ref} = new_job()

      {:ok, job} = Oban.insert(changeset)

      refute Map.has_key?(job.meta, "correlation_id")
      assert job.meta["traceparent"]
    end

    test "a whole-meta unique job is left unstamped, so it stays unique" do
      test_key!()
      Correlation.start_new()

      opts = [unique: [fields: [:worker, :meta], keys: [], period: 60]]

      {:ok, first} = Oban.insert(TestWorker.new(%{}, opts))
      {:ok, second} = Oban.insert(TestWorker.new(%{}, opts))

      assert first.id == second.id
      refute Map.has_key?(first.meta, "traceparent")
    end

    test "a non-changeset value passes through the stamping without crashing" do
      test_key!()
      assert {:error, _} = Oban.insert(TestWorker.new(%{}, priority: 99))
    end
  end

  describe "insert_all" do
    test "one producer span for the batch, stamped on every job" do
      key = test_key!()
      id = Correlation.start_new()

      changesets = for _ <- 1..3, do: TestWorker.new(%{"n" => 1})

      jobs = Oban.insert_all(changesets)

      assert length(jobs) == 3

      send_spans = Enum.filter(spans(key), &(&1.name == "send default"))
      assert [send_span] = send_spans
      assert attr(send_span, :"messaging.batch.message_count") == 3

      assert Enum.all?(jobs, &(&1.meta["correlation_id"] == id))
      assert jobs |> Enum.map(& &1.meta["traceparent"]) |> Enum.uniq() |> length() == 1
    end

    test "mixed queues name the span without a queue" do
      key = test_key!()

      changesets = [
        TestWorker.new(%{}, queue: :alpha),
        TestWorker.new(%{}, queue: :beta)
      ]

      Oban.insert_all(changesets)

      span = span_named(key, "send")
      assert span
      assert attr(span, :"messaging.destination.name") == nil
    end

    test "existing meta survives in a batch" do
      test_key!()

      [job] = Oban.insert_all([TestWorker.new(%{}, meta: %{"tenant" => "acme"})])

      assert job.meta["tenant"] == "acme"
      assert job.meta["traceparent"]
    end
  end

  describe "a stream of changesets" do
    test "is enumerated once" do
      {one, _ref} = new_job()
      {two, _ref} = new_job()

      stream =
        Stream.map([one, two], fn changeset ->
          Process.put(:enumerated, Process.get(:enumerated, 0) + 1)
          changeset
        end)

      jobs = AshEnterprise.Telemetry.ObanEngine.insert_all_jobs(Oban.config(), stream, [])

      assert length(jobs) == 2
      assert Process.get(:enumerated) == 2
    end
  end

  describe "nested inline jobs" do
    @start [:oban, :job, :start]
    @stop [:oban, :job, :stop]

    defp inline_job(correlation), do: %{job: %{id: nil, meta: %{"correlation_id" => correlation}}}

    test "restore the caller's correlation at each level" do
      Correlation.put("caller")

      ObanContext.handle_start(@start, %{}, inline_job("outer"), nil)
      assert Correlation.current() == "outer"

      ObanContext.handle_start(@start, %{}, inline_job("inner"), nil)
      assert Correlation.current() == "inner"

      ObanContext.handle_stop(@stop, %{}, inline_job("inner"), nil)
      assert Correlation.current() == "outer"

      ObanContext.handle_stop(@stop, %{}, inline_job("outer"), nil)
      assert Correlation.current() == "caller"
    end

    test "a job with no caller correlation clears at the end" do
      ObanContext.handle_start(@start, %{}, inline_job("outer"), nil)
      ObanContext.handle_stop(@stop, %{}, inline_job("outer"), nil)
      assert Correlation.current() == nil
    end
  end

  describe "a failing job's exception" do
    test "records the arity of a frame, not the job" do
      key = test_key!()

      {:ok, _} =
        Oban.insert(
          AshEnterprise.Telemetry.ClauseFailingWorker.new(%{"password" => "job-secret-value"},
            max_attempts: 1
          )
        )

      Oban.drain_queue(queue: :default)

      span = eventually(fn -> span_named_ending(key, "process default") end)
      assert [%{attributes: attributes}] = span.events
      refute attributes[:"exception.stacktrace"] =~ "job-secret-value"
      assert attributes[:"exception.stacktrace"] =~ "only_never/1"
    end
  end

  describe "correlation restore" do
    test "a drained job leaves the caller's correlation alone" do
      test_key!()
      {changeset, ref} = new_job()

      id = Correlation.start_new()
      Oban.insert!(changeset)

      Correlation.put("caller")
      drain()

      assert_received {:job_ran, ^ref, ^id}
      assert Correlation.current() == "caller"
    end

    test "a job with no stamped id mints one and clears it afterwards" do
      test_key!()
      {changeset, ref} = new_job(%{"traceparent" => "kept"})
      Oban.insert!(changeset)

      assert Correlation.current() == nil
      drain()

      assert_received {:job_ran, ^ref, id}
      assert is_binary(id)
      assert Correlation.current() == nil
    end

    test "a failing job records the exception and restores the correlation" do
      key = test_key!()
      {:ok, _} = Oban.insert(FailingWorker.new(%{}, max_attempts: 1))

      Correlation.put("caller")
      assert %{failure: 0, discard: 1} = Oban.drain_queue(queue: :default)

      span = span_named(key, "process default")
      assert [%{name: "exception"}] = span.events
      assert Correlation.current() == "caller"
    end

    test "malformed job meta does not break the handler" do
      assert ObanContext.handle_start(
               [:oban, :job, :start],
               %{},
               %{job: %{id: 1, meta: nil}},
               nil
             ) == :ok

      assert ObanContext.handle_stop([:oban, :job, :stop], %{}, %{}, nil) == :ok
      assert ObanContext.handle_start([:oban, :job, :start], %{}, :garbage, nil) == :ok
    end
  end

  describe "testing: :inline" do
    test "the job runs as a child of the caller and keeps its correlation" do
      key = test_key!()
      id = Correlation.start_new()
      ref = "ref-#{System.unique_integer([:positive])}"

      Oban.Testing.with_testing_mode(:inline, fn ->
        Tracer.with_span "request.root" do
          {:ok, job} = Oban.insert(TestWorker.new(worker_args(ref)))
          assert job.state == "completed"
        end
      end)

      assert_received {:job_ran, ^ref, ^id}
      assert Correlation.current() == id

      root = span_named(key, "request.root")
      job_span = span_named(key, "process default")

      assert job_span.parent_span_id == root.span_id
      assert attr(job_span, "ash.correlation_id") == id
    end

    test "insert_all runs inline without crashing" do
      test_key!()
      id = Correlation.start_new()
      ref = "ref-#{System.unique_integer([:positive])}"

      Oban.Testing.with_testing_mode(:inline, fn ->
        jobs = Oban.insert_all([TestWorker.new(worker_args(ref))])
        assert [%{state: "completed"}] = jobs
      end)

      assert_received {:job_ran, ^ref, ^id}
    end
  end
end
