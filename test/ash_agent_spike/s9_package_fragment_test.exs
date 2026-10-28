# The spike fragment lives in the ash_agent package's test support, where the
# package never ships it. Compile it from the dependency's source before the
# host resource below includes it.
for file <- ["next_epoch.ex", "fenced_lifecycle.ex"] do
  Code.require_file(Path.join([Mix.Project.deps_paths()[:ash_agent], "test/support/spike", file]))
end

defmodule AshEnterprise.AgentSpike.S9.Job do
  @moduledoc """
  The S9 host resource: the package's spike fragment on the platform base,
  audited, with an ash_oban trigger. Test-only; its table exists only inside
  the test that migrates it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.AgentSpike.S9,
    ownership: :organization_owned,
    lifecycle?: false,
    extra_extensions: [AshOban],
    fragments: [AshAgent.Test.Spike.FencedLifecycle]

  postgres do
    table "agent_spike_s9_jobs"
    repo AshEnterprise.Repo
  end

  oban do
    triggers do
      trigger :claim do
        action :claim
        where expr(state == :queued)
        queue :agent_spike
        scheduler_cron "* * * * *"
        max_attempts 1
        use_tenant_from_record? true
        actor_persister :none
        default_actor AshEnterprise.Platform.SystemActor.oban()
        worker_module_name AshEnterprise.AgentSpike.S9.Job.ClaimWorker
        scheduler_module_name AshEnterprise.AgentSpike.S9.Job.ClaimScheduler
      end
    end
  end
end

defmodule AshEnterprise.AgentSpike.S9 do
  @moduledoc "Test-only domain for spike S9; never registered."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.AgentSpike.S9.Job do
      define :enqueue_job, action: :enqueue, args: [:label]
      define :claim_job, action: :claim
      define :complete_job, action: :complete, args: [:epoch]
    end
  end
end

defmodule AshEnterprise.AgentSpike.S9PackageFragmentTest do
  @moduledoc """
  Spike S9: does a fragment from the `ash_agent` package compose onto
  `AshEnterprise.Platform.Resource` with audit and an ash_oban trigger?

  **Reading tested.** The package ships Spark fragments (attributes, actions,
  changes and a state machine) and the host includes them through
  `fragments:` on its own base, keeping tenancy, ownership, policies,
  triggers, audit and the `postgres` block. The reading is that such a
  resource compiles, that `mix ash.codegen` derives its table, and that the
  fragment's filtered update runs through the AshEvents wrapper: one audit
  event for a write that happens, none for a stale one.

  The fragment is `AshAgent.Test.Spike.FencedLifecycle`, kept in the
  package's `test/support` so it never ships; this file compiles it from the
  dependency's source. `:claim` moves a queued row to running and takes a new
  lease epoch; `:complete` finishes it only under a filter on the current
  epoch.

  **Result: holds, with one constraint on the host.** The resource compiles
  with the fragment's state machine, the base's columns, the AshEvents
  extension and the trigger. The migration generator, run on its domain
  alone into a temporary directory, writes one migration creating the
  fragment's columns beside the base's (tenant, ownership, provenance,
  `version_number`, archival); the test runs that migration inside its
  sandbox transaction, so no migration or table is committed. Through the
  audit wrapper the fenced `:complete` records one event, and a holder of
  an older epoch fails with `StaleRecord`, leaves the row as it was and adds
  no event. The trigger claims a queued row in the row's tenant as the
  `:oban` actor, and that write is audited too.

  Constraint: the base's own lifecycle (`lifecycle?: true`, the default) is
  an AshStateMachine block too, and Spark merges a fragment's
  `state_machine` options into it rather than refusing the second one: it
  warns that the initial states are overwritten, and the resource then fails
  the lifecycle's own check (`lifecycle_status` must default to the new
  initial state). A host resource that includes a package fragment carrying
  a state machine therefore sets `lifecycle?: false` (asserted below); the
  package's state machine is the resource's lifecycle.

  Caveats: the fragment is compiled here from the dependency's source by
  `Code.require_file/1`, not as part of the dependency's own build, and the
  table exists only inside the test's sandbox transaction.

  Fallback had this failed (plan Risk 2): library resource macros taking
  `base:`/`base_opts:` instead of fragments.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.AgentSpike.S9
  alias AshEnterprise.AgentSpike.S9.Job
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.SystemActor

  # The migration generator, run on the S9 domain alone into a temporary
  # directory seeded with the repository's extension snapshot, so only the
  # table is new. Once per module: each test compiles nothing again.
  setup_all do
    dir = Path.join(System.tmp_dir!(), "agent_spike_s9_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    snapshots = Path.join(dir, "snapshots")
    File.mkdir_p!(Path.join(snapshots, "repo"))

    File.cp!(
      "priv/resource_snapshots/repo/extensions.json",
      Path.join([snapshots, "repo", "extensions.json"])
    )

    AshPostgres.MigrationGenerator.generate([S9],
      snapshot_path: snapshots,
      migration_path: Path.join(dir, "migrations"),
      name: "agent_spike_s9",
      quiet: true,
      no_shell?: true
    )

    paths = dir |> Path.join("migrations/**/*.exs") |> Path.wildcard()

    migrations =
      for path <- paths do
        [{module, _}] = Code.compile_file(path)
        version = path |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()
        {version, module}
      end

    %{migrations: migrations, source: Enum.map_join(paths, "\n", &File.read!/1)}
  end

  # Runs the generated migration inside the test's sandbox transaction. No
  # migration lock: the lock's transaction would hold the sandbox's one
  # connection while the migrator's task waits for it. Everything, the
  # schema_migrations row included, rolls back with the sandbox.
  defp migrate!({version, module}) do
    :ok =
      Ecto.Migrator.up(AshEnterprise.Repo, version, module, log: false, migration_lock: false)
  end

  defp events(job) do
    id = job.id

    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "compiling" do
    test "the fragment, the base, audit and the trigger compose on one resource" do
      assert AshStateMachine.Info.state_machine_initial_states!(Job) == [:queued]
      assert :claim in Enum.map(Ash.Resource.Info.actions(Job), & &1.name)

      for attribute <- [:label, :lease_epoch, :state, :organization_id, :version_number] do
        assert Ash.Resource.Info.attribute(Job, attribute), "missing #{attribute}"
      end

      assert AshEvents.Events in Spark.extensions(Job)
      assert [%{name: :claim}] = AshOban.Info.oban_triggers(Job)
    end

    test "with the base's lifecycle on, the merged state machine does not compile" do
      name =
        Module.concat(
          AshEnterprise.AgentSpike.S9,
          "WithLifecycle#{System.unique_integer([:positive])}"
        )

      quoted =
        quote do
          defmodule unquote(name) do
            use AshEnterprise.Platform.Resource,
              domain: AshEnterprise.AgentSpike.S9,
              ownership: :organization_owned,
              fragments: [AshAgent.Test.Spike.FencedLifecycle]

            postgres do
              table "agent_spike_s9_jobs"
              repo AshEnterprise.Repo
              migrate? false
            end
          end
        end

      error = catch_error(Code.compile_quoted(quoted))
      assert Exception.message(error) =~ "lifecycle_status"
      assert Exception.message(error) =~ ":queued"
    end
  end

  test "the migration generator derives one table with fragment and base columns",
       %{migrations: migrations, source: source} do
    assert [_one] = migrations
    assert source =~ "create table(:agent_spike_s9_jobs"

    for column <- ~w(label lease_epoch result state organization_id version_number) do
      assert source =~ ~r/add[ (]:#{column},/, "missing column #{column}"
    end
  end

  describe "writing through the audit wrapper" do
    setup %{migrations: [migration]} do
      migrate!(migration)

      ctx = tenant!()
      %{ctx: ctx, opts: [actor: SystemActor.oban(), tenant: ctx.tenant]}
    end

    test "the fenced update records one event; a stale holder records none", %{opts: opts} do
      job = S9.enqueue_job!("Send the referral letter to the cardiology clinic", opts)
      claimed = S9.claim_job!(job, opts)
      assert {claimed.state, claimed.lease_epoch} == {:running, 1}

      done = S9.complete_job!(claimed, 1, %{result: "sent"}, opts)
      assert done.state == :completed
      assert Enum.map(events(job), &to_string(&1.action)) == ["enqueue", "claim", "complete"]

      # A second job whose holder lost the lease: it still has epoch 0.
      other = S9.enqueue_job!("Send the discharge summary", opts)
      other_claimed = S9.claim_job!(other, opts)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               S9.complete_job(other_claimed, 0, %{result: "late"}, opts)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      reread = Ash.get!(Job, other.id, opts)
      assert {reread.state, reread.result, reread.lease_epoch} == {:running, nil, 1}
      assert length(events(other)) == 2
    end

    test "the trigger claims a queued row in its tenant, audited", %{opts: opts, ctx: ctx} do
      job = S9.enqueue_job!("Send the referral letter", opts)

      result = AshOban.Test.schedule_and_run_triggers({Job, :claim})
      assert result.success >= 1

      claimed = Ash.get!(Job, job.id, opts)

      assert {claimed.state, claimed.lease_epoch, claimed.organization_id} ==
               {:running, 1, ctx.tenant}

      assert [_enqueue, claim] = events(job)
      assert to_string(claim.action) == "claim"
      assert claim.metadata["system_actor"] == "oban"
      assert claim.user_id == nil
    end
  end
end
