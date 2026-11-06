defmodule AshEnterprise.Planning.TestKit do
  @moduledoc false
  # Fixtures for the snapshot builder, check pipeline and apply tests: a tenant whose admin
  # asks for a `planning.personal_week` plan, the shipped requirements decision published as
  # the platform baseline, and a model directory with a trivial model and validator.

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, event!: 5]

  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Decisions.Definition, as: DecisionDefinition
  alias AshEnterprise.Planning
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver

  def hex(char), do: String.duplicate(char, 64)

  def sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @validator_source """
  defmodule AshEnterprise.Planning.TestKit.Validator do
    def validate(_problem, %{"assignments" => assignments}) do
      if Enum.any?(assignments, &(&1["kind"] == "task" and &1["start_slot"] < 0)),
        do: {:error, [%{code: :negative_start, subject: "task", detail: %{}}]},
        else: :ok
    end
  end
  """

  @doc "Publishes the shipped decision as the platform baseline."
  def publish_requirements! do
    platform = Seeder.seed_platform_organization()
    Resolver.forget_platform_tenant()
    opts = [actor: SystemActor.process(), tenant: platform.id]

    xml =
      File.read!(
        Path.join(:code.priv_dir(:ash_enterprise), "dmn/canonical_planning_requirements.dmn")
      )

    definition =
      DecisionDefinition.create!(
        %{
          key: "canonical_planning.requirements",
          name: "Canonical planning requirements",
          xml: xml
        },
        opts
      )

    DecisionDefinition.publish!(definition, opts)
  end

  @doc """
  A model directory (set as `planning_model_dir` for the test) holding `key/key.mzn`,
  `key/key.mzc.mzn` and `key/validator.ex`; returns `{dir, shas}`.
  """
  def model_dir!(key) do
    dir = Path.join(System.tmp_dir!(), "planning-kit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, key))
    model = "% model #{key}\n"
    checker = "% checker #{key}\n"
    File.write!(Path.join([dir, key, key <> ".mzn"]), model)
    File.write!(Path.join([dir, key, key <> ".mzc.mzn"]), checker)
    File.write!(Path.join([dir, key, "validator.ex"]), @validator_source)
    Application.put_env(:ash_enterprise, :planning_model_dir, dir)
    {dir, %{model: sha(model), checker: sha(checker), validator: sha(@validator_source)}}
  end

  @doc "A tenant, a published model version, a personal_week binding and a requested run."
  def world!(opts \\ []) do
    admin = tenant!()
    key = "kit_week_#{System.unique_integer([:positive])}"
    {_dir, shas} = model_dir!(key)
    aopts = [actor: admin.actor, tenant: admin.tenant]

    mv =
      Planning.draft_model_version!(
        %{
          key: key,
          version: 1,
          model_sha256: shas.model,
          checker_sha256: shas.checker,
          validator_module: "AshEnterprise.Planning.TestKit.Validator",
          validator_sha256: shas.validator,
          backend_profile: %{"backend" => "fake", "solver" => "gecode"}
        },
        aopts
      )
      |> Planning.publish_model_version!(aopts)

    binding =
      Planning.bind_planning_model!(
        %{
          model_key: key,
          purpose: Keyword.get(opts, :purpose, "planning.personal_week"),
          selection: [],
          backend_profile_hash: hex("d")
        },
        aopts ++ [as_of: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

    run =
      Planning.request_planning_run!(
        %{binding_id: binding.id, model_version_id: mv.id},
        aopts ++ [authorize?: true]
      )

    %{
      admin: admin,
      mv: mv,
      binding: binding,
      run: run,
      aopts: aopts,
      oban: [actor: SystemActor.oban(), tenant: admin.tenant]
    }
  end

  @doc "An open task of the admin, optionally estimated, due or scheduled."
  def task!(world, title, estimate \\ nil, opts \\ []) do
    aopts = world.aopts
    task = Task.capture!(title, aopts)

    task =
      if estimate, do: Task.set_estimate_mine!(task.id, estimate, aopts), else: task

    case opts[:schedule] do
      {from, to} -> Task.schedule_mine!(task.id, from, to, aopts)
      nil -> task
    end
  end

  @doc """
  Prepares the world's run, takes its lease and records a `:feasible` outcome whose single
  candidate schedules every task from slot 400 in steps of 10 and attends every meeting.
  Returns `{run, payload}`.
  """
  def solved!(world, opts \\ []) do
    {:ok, prepared} = AshEnterprise.Planning.SnapshotBuilder.prepare(world.run)
    {:ok, payload} = AshEnterprise.Planning.SnapshotBuilder.problem_payload(prepared)
    tasks = length(payload["ids"]["tasks"])
    meetings = length(payload["ids"]["meetings"])

    candidate =
      Map.merge(
        %{
          "index" => 1,
          "objective" => "3",
          "checker_output" => nil,
          "checker_ok" => true,
          "data" => %{
            "scheduled" => List.duplicate(true, tasks),
            "start" => Enum.map(0..(tasks - 1)//1, &(400 + &1 * 10)),
            "attended" => List.duplicate(true, meetings)
          }
        },
        Map.new(Keyword.get(opts, :candidate, []))
      )

    started =
      Planning.start_planning_run!(
        prepared,
        %{backend: %{"backend" => "fake"}, session_pid: "test"},
        world.oban
      )

    solved =
      Planning.record_planning_result!(
        started,
        %{
          solve_status: :feasible,
          complete?: false,
          optimality: :none,
          outcome_reason: :time_limit,
          result_payload: Jason.encode!(%{"candidates" => [candidate]}),
          epoch: started.lease_epoch
        },
        world.oban
      )

    {solved, payload}
  end

  def event(%{admin: admin}, title, starts_at, minutes),
    do: event!(admin, title, 0, minutes, starts_at: starts_at)
end
