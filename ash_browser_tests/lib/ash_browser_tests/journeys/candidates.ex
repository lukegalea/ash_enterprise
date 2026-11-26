if Code.ensure_loaded?(AshJourneys.Run) do
  defmodule AshBrowserTests.Journeys.Candidates do
    @moduledoc """
    Where one run of one journey in one locale writes its manifest and figures:
    `tmp/journeys/runs/<run-id>/<journey>/<locale>/` (`AshJourneys.Run`).

    ## The run id

    `JOURNEYS_RUN_ID` when it is set, so every journey of one CI run lands in one
    run, and a re-run of failed tests under the same id is recorded as a retry.
    Otherwise `local-<date>-<OS pid>`: one run per test VM.

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
            prior: Manifest.t() | :unreadable | nil
          }

    @doc "This run's id (see the moduledoc)."
    @spec run_id() :: String.t()
    def run_id do
      case System.get_env("JOURNEYS_RUN_ID") do
        id when id in [nil, ""] ->
          "local-#{Date.to_iso8601(Date.utc_today(), :basic)}-#{System.pid()}"

        id ->
          id
      end
    end

    @doc """
    Claims the candidate directory of `journey` in `locale` for run `run_id`
    under the project root `root`. `prior` is the manifest of an earlier attempt
    of the same run (`:unreadable` when it left none that reads), or `nil`.
    """
    @spec claim!(Path.t(), String.t(), String.t(), String.t()) :: t()
    def claim!(root, run_id, journey, locale), do: claim!(root, run_id, journey, locale, 1)

    defp claim!(root, run_id, journey, locale, n) do
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
            {:ok, ^me} -> claim!(root, run_id, journey, locale, n + 1)
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
