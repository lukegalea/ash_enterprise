defmodule AshEnterprise.Showcase.HistoryTwoNodeTest do
  @moduledoc """
  `mix ash_enterprise.demo --history` beside a running server, on one database (the
  durability tier: real commits, a real Oban). This node is the server: its Oban runs every
  queue. A second BEAM (`:peer`) is the seed: it boots the application exactly as the task
  does under `--history` (`HeldJobs.oban_config/1`) and runs `History.run!/1`.

    * A fault point armed in the seed is armed in the seed only: the server's points stay
      quiet while the seed's fire.
    * The seed fetches nothing it did not insert: a job waiting in the server's table is
      untouched by the run.
    * Every beat still ends in its failure while the server's queues run beside it, so the
      faulted beats' jobs ran in the seed, armed, and not in the server.
    * Nothing stays armed in the seed and no job stays held.

  SYNTHETIC data only.
  """

  use AshEnterprise.DurabilityCase, async: false

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true
  @moduletag timeout: :timer.minutes(10)

  import Ecto.Query, only: [from: 2]

  alias AshEnterprise.Credentialing.DemoData
  alias AshEnterprise.Platform.DemoTenant
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Showcase.History
  alias AshEnterprise.Showcase.History.HeldJobs

  @seed_node "history-seed"
  # Applications whose environment is the node's own, not the project's configuration.
  @own_env [:kernel, :stdlib, :ex_unit, :mix, :iex, :elixir]

  setup do
    Faults.disarm_all()
    organization = DemoTenant.provision!()
    DemoData.populate(organization.id)

    seed = start_seed!()

    on_exit(fn ->
      if Process.alive?(seed), do: :peer.stop(seed)
    end)

    %{organization: organization, seed: seed}
  end

  # A second node on this node's code and configuration, whose Oban is the seed's.
  defp start_seed! do
    {:ok, seed, _node} = :peer.start(%{connection: :standard_io})
    :ok = :peer.call(seed, :code, :add_pathsa, [:code.get_path()])

    env =
      for {app, _description, _vsn} <- Application.loaded_applications(),
          app not in @own_env do
        {app, Application.get_all_env(app)}
      end

    oban =
      :ash_enterprise
      |> Application.fetch_env!(Oban)
      |> HeldJobs.oban_config()
      |> Keyword.put(:node, @seed_node)

    env =
      env
      |> Enum.map(fn
        {:ash_enterprise, config} ->
          {:ash_enterprise,
           config |> Keyword.delete(:__armed_faults__) |> Keyword.put(Oban, oban)}

        other ->
          other
      end)

    for {app, _config} <- env, do: :peer.call(seed, :application, :load, [app])
    :ok = :peer.call(seed, Application, :put_all_env, [env, [persistent: true]])
    :ok = :peer.call(seed, Logger, :configure, [[level: :error]])

    {:ok, _started} =
      :peer.call(seed, Application, :ensure_all_started, [:ash_enterprise], :timer.minutes(2))

    seed
  end

  defp seed_call(seed, module, fun, args),
    do: :peer.call(seed, module, fun, args, :timer.minutes(8))

  defp jobs_attempted_by(node) do
    Repo.all(
      from(j in "oban_jobs",
        where: fragment("?[1] = ?", j.attempted_by, ^node),
        select: j.id
      ),
      prefix: Oban.config().prefix
    )
  end

  defp held_jobs do
    Repo.aggregate(
      from(j in "oban_jobs", where: fragment("? \\? 'held_by'", j.meta)),
      :count,
      prefix: Oban.config().prefix
    )
  end

  test "a point armed in the seed fires in the seed only", %{seed: seed} do
    :ok = seed_call(seed, Tour, :arm_lost_answer, [])

    for point <- Tour.lost_answer_points() do
      # The server: never armed, quiet.
      assert Faults.point(point) == :ok
      # The seed: armed, fires.
      assert {:fired, _kind} = fire(seed, point)
    end

    for point <- Tour.lost_answer_points(), do: seed_call(seed, Faults, :disarm, [point])
    assert Faults.point(:credential_registry_accepted) == :ok
  end

  test "every beat ends in its failure while the server runs its queues, and the seed takes no job of the server's",
       %{organization: organization, seed: seed} do
    # A job of the server's, in a queue nobody runs: the seed must leave it as it is.
    {:ok, waiting} =
      %{"note" => "the server's own"}
      |> Oban.Job.new(worker: "AshEnterprise.Showcase.NoSuchWorker", queue: "history_sentinel")
      |> Oban.insert()

    report = seed_call(seed, History, :run!, [organization])

    assert Enum.map(report, & &1.beat) == History.beats()
    assert Map.new(report, &{&1.beat, &1.status}) == Map.new(History.beats(), &{&1, :produced})

    # The seed ran the held jobs, and only those.
    assert jobs_attempted_by(@seed_node) != []
    refute waiting.id in jobs_attempted_by(@seed_node)

    assert %{state: "available", attempt: 0} =
             Repo.one(
               from(j in "oban_jobs",
                 where: j.id == ^waiting.id,
                 select: %{state: j.state, attempt: j.attempt}
               ),
               prefix: Oban.config().prefix
             )

    # Nothing armed in the seed, nothing armed here, nothing held.
    assert seed_call(seed, Application, :get_env, [:ash_enterprise, :__armed_faults__, %{}]) ==
             %{}

    assert Faults.point(:credential_registry_accepted) == :ok
    assert held_jobs() == 0

    # A second run, beside the server, finds every beat.
    again = seed_call(seed, History, :run!, [organization])
    assert Map.new(again, &{&1.beat, &1.status}) == Map.new(History.beats(), &{&1, :already})
  end

  # Hits `point` in the seed and says whether it fired there.
  defp fire(seed, point) do
    case seed_call(seed, Faults, :point, [point]) do
      :ok -> :quiet
    end
  catch
    kind, _reason -> {:fired, kind}
  end
end
