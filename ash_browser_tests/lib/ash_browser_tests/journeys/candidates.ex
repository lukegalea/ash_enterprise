if Code.ensure_loaded?(AshJourneys.Run) do
  defmodule AshBrowserTests.Journeys.Candidates do
    @moduledoc """
    Where one run of one journey in one locale writes its manifest and figures:
    `tmp/journeys/runs/<run-id>/<journey>/<locale>/` (`AshJourneys.Run`).

    ## The run id and its attempts

    `JOURNEYS_RUN_ID` when it is set, so every journey of one CI run lands in one
    run. Otherwise `local-<commit>`, the first 12 characters of the checkout's
    HEAD (`local-<date>-<OS pid>` outside a git checkout): every test VM at one
    commit is the same run, so a second `mix test` of a journey at that commit is
    recorded as a retry of the first. Start a fresh run with `JOURNEYS_RUN_ID`, or
    by removing its directory.

    `JOURNEYS_RUN_ATTEMPT` (default 1) is the attempt of the run this is: a CI
    runner re-running a job starts with an empty directory, so the attempt is
    the only record that an earlier one ran. Set it to the CI's attempt number
    (GitHub's `run_attempt`) and keep it out of `JOURNEYS_RUN_ID`. Every attempt
    after the first is a retry.

    ## Claims

    A test claims its candidate directory before it writes anything, by creating
    a `.claim` file there exclusively, holding the OS pid of its VM. Nothing else
    in the directory is ever written by two tests:

      * a claim held by this VM is another test of the same journey and locale,
        running now or earlier in this VM (a second module running it, a
        negative test): that test takes the next free run id, `<run-id>-2`,
        `<run-id>-3`, …;
      * a claim held by another process is an earlier attempt of this run (the
        same run id, re-run): the directory is taken over, its figures cleared,
        and the earlier manifest returned, so the new manifest counts the retry.

    A retried run is never approvable: approval takes only a pass on the first
    attempt (`AshJourneys.Approval`).
    """

    alias AshJourneys.Manifest
    alias AshJourneys.Run

    @claim ".claim"

    @type t :: %{
            run_id: String.t(),
            dir: Path.t(),
            prior: Manifest.t() | :unreadable | nil,
            earlier_attempts: non_neg_integer()
          }

    @doc "This run's id (see the moduledoc)."
    @spec run_id() :: String.t()
    def run_id do
      case System.get_env("JOURNEYS_RUN_ID") do
        id when id in [nil, ""] -> local_run_id()
        id -> id
      end
    end

    @doc "The run id when `JOURNEYS_RUN_ID` is not set (see the moduledoc)."
    @spec local_run_id() :: String.t()
    def local_run_id do
      case System.cmd("git", ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> "local-" <> String.trim(sha)
        _not_a_checkout -> "local-#{Date.to_iso8601(Date.utc_today(), :basic)}-#{System.pid()}"
      end
    rescue
      _no_git -> "local-#{Date.to_iso8601(Date.utc_today(), :basic)}-#{System.pid()}"
    end

    @doc "This run's attempt: `JOURNEYS_RUN_ATTEMPT`, or 1 (see the moduledoc)."
    @spec attempt() :: pos_integer()
    def attempt do
      case Integer.parse(System.get_env("JOURNEYS_RUN_ATTEMPT") || "1") do
        {n, ""} when n >= 1 -> n
        _other -> raise ArgumentError, "JOURNEYS_RUN_ATTEMPT must be a positive integer"
      end
    end

    @doc """
    Claims the candidate directory of `journey` in `locale` for run `run_id`
    under the project root `root`, in the run's `attempt`. `prior` is the
    manifest of an earlier attempt of the same run in this directory
    (`:unreadable` when it left none that reads), or `nil`; `earlier_attempts`
    counts the attempts before `attempt`.
    """
    @spec claim!(Path.t(), String.t(), String.t(), String.t(), pos_integer()) :: t()
    def claim!(root, run_id, journey, locale, attempt \\ attempt()) do
      root
      |> claim_dir!(run_id, journey, locale, 1)
      |> Map.put(:earlier_attempts, attempt - 1)
    end

    defp claim_dir!(root, run_id, journey, locale, n) do
      id = if n == 1, do: run_id, else: "#{run_id}-#{n}"
      dir = Run.candidate_dir(root, id, journey, locale)
      File.mkdir_p!(dir)
      claim = Path.join(dir, @claim)
      me = System.pid()

      # Written aside, then hard-linked into place: the link is atomic and fails
      # when a claim exists, so no reader ever sees a claim without its pid.
      pending = Path.join(dir, ".claim-#{me}-#{System.unique_integer([:positive])}")
      File.write!(pending, me)
      linked = File.ln(pending, claim)
      File.rm!(pending)

      case linked do
        :ok ->
          %{run_id: id, dir: dir, prior: nil}

        {:error, :eexist} ->
          case File.read(claim) do
            {:ok, ^me} -> claim_dir!(root, run_id, journey, locale, n + 1)
            _earlier -> take_over(dir, claim, me, id)
          end
      end
    end

    defp take_over(dir, claim, me, id) do
      prior =
        case Manifest.read(Path.join(dir, Manifest.file_name())) do
          {:ok, manifest} -> manifest
          {:error, _problems} -> :unreadable
        end

      for file <- File.ls!(dir), file != @claim, do: File.rm_rf!(Path.join(dir, file))
      File.write!(claim, me)
      %{run_id: id, dir: dir, prior: prior}
    end
  end
end
