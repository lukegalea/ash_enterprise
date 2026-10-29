defmodule AshEnterprise.Durability do
  @moduledoc """
  The durability tier's harness: the suite switch, and the helpers its tests share.

  The tier exists for the claims the SQL sandbox cannot test. A sandboxed test runs on one
  connection inside one transaction that is rolled back at the end, so nothing it does is ever
  committed, no second connection ever sees it, and two "concurrent" writers are really one.
  A compare-and-set race, a job that dies between two commits, a retry that must find the
  first commit and not repeat it: each of those is a statement about committed state seen by
  more than one connection, and needs the real thing.

  So a durability run (`mix test.durability`, docs/DURABILITY-TESTS.md) has no sandbox pool,
  a database of its own named after `MIX_TEST_PARTITION`, and a real Oban executing jobs. The
  database is dropped before the run (a previous run that was killed leaves one behind) and
  again when the suite ends. Tests in it commit for real, so each one keys its rows by
  something unique rather than relying on a rollback.
  """

  import ExUnit.Assertions

  alias AshEnterprise.Repo

  @doc "Whether this run is the durability tier (`ASH_ENTERPRISE_DURABILITY` set at config time)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:ash_enterprise, :durability?, false)

  @doc "The dedicated database this run commits to."
  @spec database() :: String.t()
  def database, do: Repo.config()[:database]

  @doc """
  Configures ExUnit for a durability run: only `:durability` tests, one at a time, and the
  database dropped when the suite ends. Called from `test_helper.exs`.
  """
  @spec configure_suite!() :: :ok
  def configure_suite! do
    # Excluding every test and including the tier is what `--only durability` does; doing it
    # here means a durability run cannot pick up a sandboxed test by accident, which would
    # fail on the missing sandbox at best and commit into this database at worst.
    ExUnit.configure(exclude: [:test], include: [:durability], max_cases: 1)
    ExUnit.after_suite(fn _result -> drop_database!() end)
    :ok
  end

  @doc """
  Stops the application and drops the dedicated database.

  The application first: its pools and Oban's notifier hold connections, and dropping the
  database under them turns a clean exit into a screen of disconnection errors.
  """
  @spec drop_database!() :: :ok
  def drop_database! do
    config = Repo.config()
    :ok = Application.stop(:ash_enterprise)

    case Ecto.Adapters.Postgres.storage_down(Keyword.put(config, :force_drop, true)) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> raise "could not drop #{config[:database]}: #{inspect(reason)}"
    end
  end

  @doc """
  Forwards this node's Oban job outcomes to the calling process until the test ends.

  Each finished job arrives as `{:oban_job, job_id, state, meta}`, where `state` is Oban's:
  `:success`, `:failure`, `:discard`, `:cancelled` or `:snoozed`. The message is sent after
  Oban has recorded the outcome, so a test that receives it can read the job's row and see
  the same thing. A job killed outright arrives as `:failure` with `meta.kind == :exit`.
  """
  @spec subscribe_jobs() :: :ok
  def subscribe_jobs do
    test = self()
    id = {__MODULE__, :jobs, test, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        &__MODULE__.forward_job_event/4,
        test
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward_job_event(_event, _measurements, %{job: job, state: state} = meta, test) do
    send(test, {:oban_job, job.id, state, meta})
  end

  @doc """
  Waits for the job `job_id` to finish in `state`, and returns the event's metadata.

  Outcomes of the same job in other states are skipped, so a test can wait for a job's eventual
  success straight through its failed attempts. Fails after `timeout` milliseconds.
  """
  @spec await_job(integer(), atom(), timeout()) :: map()
  def await_job(job_id, state, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_job_until(job_id, state, deadline)
  end

  defp await_job_until(job_id, state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:oban_job, ^job_id, ^state, meta} -> meta
      {:oban_job, ^job_id, _other, _meta} -> await_job_until(job_id, state, deadline)
    after
      remaining -> flunk("job #{job_id} did not finish as #{inspect(state)} in time")
    end
  end

  @doc "The job's row as it is committed now, read on a connection of its own."
  @spec job!(integer()) :: Oban.Job.t()
  def job!(job_id), do: Repo.get!(Oban.Job, job_id)

  @doc """
  Runs `fun` in `count` processes released at the same moment, and returns the results in
  order.

  Each process is held at a barrier until all of them exist, so the calls overlap as closely as
  the scheduler allows: the shape a compare-and-set needs to be tested against. `fun` receives
  the process's index, from 0.
  """
  @spec race(pos_integer(), (non_neg_integer() -> result), timeout()) :: [result]
        when result: term()
  def race(count, fun, timeout \\ 30_000) when is_integer(count) and count > 0 do
    tasks =
      for index <- 0..(count - 1) do
        Task.async(fn ->
          receive do
            :go -> fun.(index)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, timeout)
  end
end
