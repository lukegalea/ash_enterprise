defmodule AshEnterprise.LineageTest do
  @moduledoc """
  The lineage store, end to end below the web: events coalesce into jobs,
  runs and job runs; whose run an event is comes from host metadata and
  never from the event; facets stay structural; the graph derives per
  window and job; nobody reads another tenant's lineage; retention deletes.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, person!: 3]
  import AshEnterprise.Test.LineageFixtures

  alias AshEnterprise.Lineage.{Diagram, Graph, Job, JobRun, Recorder, Retention, Run, Store}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Surfaces

  require Ash.Query

  @sources %{"namespace" => "ingestion", "name" => "ingestion_source_objects"}
  @messages %{"namespace" => "canonical", "name" => "canonical_messages"}

  setup do
    inline_store!()
    %{admin: quietly(&tenant!/0)}
  end

  # A sync-shaped batch: the sync's START, `rows` landings with no tenant of
  # their own, a projection, and the sync's end.
  defp sync_batch(tenant, opts \\ []) do
    correlation = Keyword.get(opts, :correlation, Ash.UUID.generate())
    at = Keyword.get(opts, :at, DateTime.utc_now())
    rows = Keyword.get(opts, :rows, 3)
    land_run = AshEnterprise.Lineage.job_run_id(correlation, "ingestion", "source_object.land")
    project_run = AshEnterprise.Lineage.job_run_id(correlation, "canonical", "projection.gmail")
    meta = %{tenant: tenant, linked_account_id: opts[:linked_account_id]}
    later = fn seconds -> DateTime.add(at, seconds, :second) end

    sync = fn type, extra ->
      event(
        type,
        "ingestion",
        "gmail.sync",
        [run_id: correlation, inputs: ["gmail.source"], outputs: [@sources]] ++ extra
      )
    end

    landings =
      for n <- 1..rows do
        {event(:complete, "ingestion", "source_object.land",
           run_id: land_run,
           correlation_id: correlation,
           outputs: [@sources],
           at: later.(n)
         ), %{tenant: nil}}
      end

    ending =
      case Keyword.get(opts, :outcome, :complete) do
        :complete -> {sync.(:complete, at: later.(rows + 2)), meta}
        :fail -> {sync.(:fail, at: later.(rows + 2), error: "unauthorized"), meta}
        :running -> nil
      end

    entries =
      [{sync.(:start, at: at), meta}] ++
        landings ++
        [
          {event(:start, "canonical", "projection.gmail",
             run_id: project_run,
             correlation_id: correlation,
             inputs: [@sources],
             outputs: [@messages],
             at: later.(rows + 1)
           ), meta},
          {event(:complete, "canonical", "projection.gmail",
             run_id: project_run,
             correlation_id: correlation,
             inputs: [@sources],
             outputs: [@messages],
             at: later.(rows + 1)
           ), meta}
        ] ++ List.wrap(ending)

    {correlation, entries}
  end

  defp read(resource, %{actor: actor, tenant: tenant}),
    do: resource |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant) |> Ash.read!()

  defp job_runs(run_id, admin) do
    JobRun
    |> Ash.Query.filter(lineage_run_id == ^run_id)
    |> Ash.read!(actor: admin.actor, tenant: admin.tenant)
    |> Map.new(&{JobRun.label(&1), &1})
  end

  describe "the store" do
    test "a sync's events are one run: its jobs coalesce, untenanted landings inherit its tenant",
         %{admin: admin} do
      {correlation, entries} = sync_batch(admin.tenant, rows: 50)
      assert %{events: 54, runs: 1, job_runs: 3, jobs: 3, dropped: 0} = Recorder.write(entries)

      run =
        Ash.get!(Run, correlation,
          actor: admin.actor,
          tenant: admin.tenant,
          load: [:state, :job_count, :event_count]
        )

      assert run.correlation_id == correlation
      assert run.job_label == "ingestion.gmail.sync"
      assert %{state: :complete, job_count: 3, event_count: 54} = run

      runs = job_runs(correlation, admin)
      land = runs["ingestion.source_object.land"]
      assert land.event_count == 50
      assert land.organization_id == admin.tenant
      assert land.outputs == [@sources]

      projection = runs["canonical.projection.gmail"]
      assert projection.inputs == [@sources]
      assert projection.outputs == [@messages]
      assert projection.state == :complete
    end

    test "writing a run's later events updates it rather than adding rows", %{admin: admin} do
      {correlation, entries} = sync_batch(admin.tenant, outcome: :running)
      Recorder.write(entries)

      assert %{state: :running} =
               Ash.get!(Run, correlation, actor: admin.actor, tenant: admin.tenant, load: :state)

      Recorder.write([
        {event(:fail, "ingestion", "gmail.sync", run_id: correlation, error: "unauthorized"),
         %{tenant: admin.tenant}}
      ])

      run =
        Ash.get!(Run, correlation,
          actor: admin.actor,
          tenant: admin.tenant,
          load: [:state, :error_message, :job_count]
        )

      assert %{state: :failed, error_message: "unauthorized", job_count: 3} = run

      sync = job_runs(correlation, admin)["ingestion.gmail.sync"]
      assert %{state: :failed, event_count: 2} = sync
      assert sync.ended_at

      [job] =
        Job
        |> Ash.Query.filter(name == "gmail.sync")
        |> Ash.read!(actor: admin.actor, tenant: admin.tenant)

      assert %{last_state: :failed, last_error: "unauthorized", run_count: 1} = job
    end

    test "another tenant's events inside a correlation are that tenant's own run", %{
      admin: admin
    } do
      other = quietly(&tenant!/0)
      {correlation, entries} = sync_batch(admin.tenant)

      foreign =
        {event(:complete, "canonical", "message.upsert",
           run_id: AshEnterprise.Lineage.job_run_id(correlation, "canonical", "message.upsert"),
           correlation_id: correlation,
           outputs: [@messages]
         ), %{tenant: other.tenant}}

      Recorder.write(entries ++ [foreign])

      assert [%Run{id: ^correlation}] = read(Run, admin)
      assert [%Run{id: theirs, correlation_id: ^correlation}] = read(Run, other)
      refute theirs == correlation
      assert ["canonical.message.upsert"] = read(JobRun, other) |> Enum.map(&JobRun.label/1)
      refute "canonical.message.upsert" in Enum.map(read(JobRun, admin), &JobRun.label/1)
    end

    test "a correlation no tenant touched belongs to the platform organization", %{admin: admin} do
      platform = Seeder.seed_platform_organization()
      correlation = Ash.UUID.generate()

      Recorder.write([
        {event(:complete, "security", "privilege.create", run_id: correlation), %{tenant: nil}}
      ])

      assert [] = read(Run, admin)

      assert %Run{organization_id: org} =
               Ash.get!(Run, correlation, authorize?: false, tenant: platform.id)

      assert org == platform.id
    end

    test "the buffered store writes what it collected on flush, in one write", %{admin: admin} do
      store = start_supervised!({Store, name: :lineage_store_test, flush_interval_ms: 60_000})
      Ecto.Adapters.SQL.Sandbox.allow(AshEnterprise.Repo, self(), store)

      {correlation, entries} = sync_batch(admin.tenant, rows: 20)
      Enum.each(entries, &GenServer.cast(store, {:record, &1}))

      assert %{events: 24, runs: 1, job_runs: 3} = Store.flush(store)
      assert %{events: 0} = Store.flush(store)
      assert %Run{} = Ash.get!(Run, correlation, actor: admin.actor, tenant: admin.tenant)
    end

    test "every write broadcasts on its tenant's topic", %{admin: admin} do
      Phoenix.PubSub.subscribe(AshEnterprise.PubSub, Recorder.topic(admin.tenant))
      {_correlation, entries} = sync_batch(admin.tenant)
      Recorder.write(entries)
      tenant = admin.tenant
      assert_receive {:lineage_recorded, ^tenant}
    end
  end

  describe "facets stay structural" do
    test "what a real write records carries no actor, tenant or value", %{admin: admin} do
      name = "Lineage Leak #{System.unique_integer([:positive])}"
      email = "lineage-leak-#{System.unique_integer([:positive])}@example.test"
      person!(admin, email, name)

      jobs = read(Job, admin)
      assert Enum.any?(jobs, &String.starts_with?(&1.label, "canonical.person."))

      rows = jobs ++ read(Run, admin) ++ read(JobRun, admin)
      assert rows != []

      # organization_id is the host's own row scoping (it is how nobody reads
      # another tenant's lineage); everything else is what the event carried.
      forbidden = [admin.tenant, admin.user.id, admin.email, name, email]

      for row <- rows,
          {field, value} <- Map.from_struct(row),
          field not in [:organization_id, :__meta__, :__metadata__, :aggregates, :calculations] do
        text = inspect(value)

        for value <- forbidden,
            do: refute(text =~ value, "#{inspect(row.__struct__)}.#{field} leaks #{value}")
      end

      # ...and the host metadata did reach the store: the run is the tenant's.
      assert Enum.all?(rows, &(&1.organization_id == admin.tenant))
    end
  end

  describe "the graph" do
    test "datasets and jobs are nodes; each job's latest run is its edges", %{admin: admin} do
      {_correlation, entries} = sync_batch(admin.tenant, outcome: :fail)
      Recorder.write(entries)

      {:ok, graph} = Graph.derive(actor: admin.actor, tenant: admin.tenant)

      labels = Map.new(graph.nodes, &{&1.label, &1})
      sync = labels["ingestion.gmail.sync"]
      projection = labels["canonical.projection.gmail"]
      gmail = labels["ingestion/gmail.source"]
      sources = labels["ingestion/ingestion_source_objects"]
      messages = labels["canonical/canonical_messages"]

      assert %{kind: :job, state: :failed} = sync
      assert %{kind: :dataset} = sources

      edges = Map.new(graph.edges, &{{&1.from, &1.to}, &1.state})
      assert edges[{gmail.id, sync.id}] == :failed
      assert edges[{sync.id, sources.id}] == :failed
      assert edges[{sources.id, projection.id}] == :complete
      assert edges[{projection.id, messages.id}] == :complete
    end

    test "a failed run is a red marker that opens its run; the drawing carries no state", %{
      admin: admin
    } do
      {correlation, entries} = sync_batch(admin.tenant, outcome: :fail)
      Recorder.write(entries)

      {:ok, %{source: source, markers: markers}} =
        Diagram.diagram(%{actor: admin.actor, tenant: admin.tenant, contexts: %{}})

      assert source =~ "flowchart LR"
      assert source =~ ~s|("ingestion.gmail.sync")|
      assert source =~ ~s|[("ingestion/ingestion_source_objects")]|
      refute source =~ "failed"

      failed = Enum.find(markers, &(&1.status == :failed))
      assert failed.label =~ "ingestion.gmail.sync: failed"
      assert failed.link == {Run, correlation}
      assert Enum.any?(markers, &(&1.status == :done))

      # On the surface's wire: the danger tone is the red fill, and the
      # runs table's badge says the same.
      %{"updateDataModel" => %{"value" => value}} =
        AshA2ui.Info.build_data_model(AshEnterpriseWeb.A2ui.LineageUI,
          actor: admin.actor,
          tenant: admin.tenant
        )

      wire = value["diagram"]["graph"]["markers"] |> Map.values() |> List.flatten()
      assert Enum.any?(wire, &(&1["status"] == "failed" and &1["tone"] == "danger"))

      assert [%{"id" => ^correlation, "_badge_tone_state" => "danger"}] =
               value["records"]["table"]
    end

    test "a window and a job narrow it", %{admin: admin} do
      old = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
      {_c, entries} = sync_batch(admin.tenant, at: old)
      Recorder.write(entries)

      calendar = Ash.UUID.generate()

      Recorder.write([
        {event(:complete, "ingestion", "calendar.sync",
           run_id: calendar,
           inputs: ["calendar.source"],
           outputs: [@sources]
         ), %{tenant: admin.tenant}},
        {event(:complete, "canonical", "calendar_event.upsert",
           run_id:
             AshEnterprise.Lineage.job_run_id(calendar, "canonical", "calendar_event.upsert"),
           correlation_id: calendar,
           outputs: [%{"namespace" => "canonical", "name" => "canonical_calendar_events"}]
         ), %{tenant: admin.tenant}}
      ])

      jobs = fn opts ->
        {:ok, graph} = Graph.derive([actor: admin.actor, tenant: admin.tenant] ++ opts)
        graph.jobs |> Enum.map(& &1.label) |> Enum.sort()
      end

      assert jobs.(window: "day") == [
               "canonical.calendar_event.upsert",
               "ingestion.calendar.sync"
             ]

      assert "ingestion.gmail.sync" in jobs.(window: "week")

      [calendar_job] =
        Job
        |> Ash.Query.filter(name == "calendar.sync")
        |> Ash.read!(actor: admin.actor, tenant: admin.tenant)

      # The calendar sync's neighbourhood: itself, and the jobs sharing its
      # datasets inside the window (the gmail sync shares the landing table).
      assert jobs.(window: "week", job_id: calendar_job.id) ==
               [
                 "canonical.projection.gmail",
                 "ingestion.calendar.sync",
                 "ingestion.gmail.sync",
                 "ingestion.source_object.land"
               ]

      assert jobs.(window: "day", job_id: calendar_job.id) == ["ingestion.calendar.sync"]
    end
  end

  describe "who may read it" do
    test "a role grant opens it; no grant, another tenant or no tenant sees nothing", %{
      admin: admin
    } do
      {correlation, entries} = sync_batch(admin.tenant)
      Recorder.write(entries)

      viewer =
        quietly(fn ->
          member!(admin, "Lineage viewer", [
            {Run, :read, :global},
            {JobRun, :read, :global},
            {Job, :read, :global}
          ])
        end)

      nobody = quietly(fn -> member!(admin, "Nothing", []) end)
      stranger = quietly(&tenant!/0)

      assert [%Run{id: ^correlation}] = read(Run, viewer)
      assert Surfaces.open?(Surfaces.fetch!(:lineage), viewer.actor)
      assert Surfaces.open?(Surfaces.fetch!(:lineage), admin.actor)

      assert [] = read(Run, nobody)
      assert [] = read(JobRun, nobody)
      refute Surfaces.open?(Surfaces.fetch!(:lineage), nobody.actor)
      assert {:ok, %{jobs: []}} = Graph.derive(actor: nobody.actor, tenant: nobody.tenant)

      assert [] = read(Run, stranger)
      assert {:ok, %{jobs: []}} = Graph.derive(actor: stranger.actor, tenant: stranger.tenant)

      # The graph always reads inside one tenant; with none it is empty.
      assert {:ok, %{jobs: []}} = Graph.derive(actor: nil, tenant: nil)
    end

    test "only the store writes", %{admin: admin} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Run
               |> Ash.Changeset.for_create(
                 :record,
                 %{
                   id: Ash.UUID.generate(),
                   correlation_id: Ash.UUID.generate(),
                   job_label: "forged.job",
                   first_event_at: DateTime.utc_now(),
                   last_event_at: DateTime.utc_now()
                 },
                 actor: admin.actor,
                 tenant: admin.tenant
               )
               |> Ash.create()
    end

    test "the ACP prompt reads the same graph as the actor", %{admin: admin} do
      {_correlation, entries} = sync_batch(admin.tenant, outcome: :fail)
      Recorder.write(entries)

      text =
        AshEnterprise.Agents.Console.lineage!(:day, actor: admin.actor, tenant: admin.tenant)

      assert text =~ "Lineage, last 24 hours — 3 jobs"
      assert text =~ "1 failed"
      assert text =~ "✕ ingestion.gmail.sync — failed"
      assert text =~ ": unauthorized"

      nobody = quietly(fn -> member!(admin, "Nothing", []) end)

      # Behind the Lineage door: someone without it is neither offered the
      # command (the palette prunes on this policy) nor answered.
      assert {:error, %Ash.Error.Forbidden{}} =
               AshEnterprise.Agents.Console.lineage(:day,
                 actor: nobody.actor,
                 tenant: nobody.tenant
               )
    end
  end

  describe "retention" do
    test "runs and jobs past the window are deleted, their job runs with them", %{admin: admin} do
      old = DateTime.add(DateTime.utc_now(), -20 * 86_400, :second)
      {old_run, old_entries} = sync_batch(admin.tenant, at: old)
      {new_run, new_entries} = sync_batch(admin.tenant)

      old_calendar = Ash.UUID.generate()

      Recorder.write(
        old_entries ++
          new_entries ++
          [
            {event(:complete, "ingestion", "calendar.sync", run_id: old_calendar, at: old),
             %{tenant: admin.tenant}}
          ]
      )

      assert %{runs: 2, jobs: 1} = Retention.prune()

      assert [%Run{id: ^new_run}] = read(Run, admin)
      assert job_runs(old_run, admin) == %{}
      assert map_size(job_runs(new_run, admin)) == 3
      refute Enum.any?(read(Job, admin), &(&1.name == "calendar.sync"))
      assert %{runs: 0, jobs: 0} = Retention.prune()
    end
  end
end
