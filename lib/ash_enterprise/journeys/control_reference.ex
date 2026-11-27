defmodule AshEnterprise.Journeys.ControlReference do
  @moduledoc """
  `journey:<id>` references in `docs/controls.json`, for `ash_compliance`'s control-file
  check (`AshCompliance.Ownership.ReferenceScheme`, configured in `config/config.exs`).

  A row may name a journey as its evidence producer or its test. Either way the reference
  resolves only while the journey proves what it claims:

    * `<id>` is a journey the configured modules declare (`AshJourneys.Lock.declared/0`);
    * in every locale it declares, the run the lock names still proves it
      (`AshJourneys.Lock.verify/6`): approved, not stale (the declaration and the pinned
      browser build are the approved ones), not altered and not drifted.

  A test file that merely exists proves nothing about the control; an approved, current
  run of the journey does.

  As a producer, a journey records evidence for the criteria its `metadata controls`
  names: those are what `AshEnterprise.Journeys.EvidenceSink` records a passing run
  against. Under `--require-producer-proof`, a row whose criterion the journey does not
  name is unproven.

  Both answers come from the compiled declarations and the files under `priv/journeys/`,
  never from a database: the check runs in CI with nothing started.
  """

  @behaviour AshCompliance.Ownership.ReferenceScheme

  alias AshJourneys.Lock

  @impl true
  def resolve(id, root) do
    with {:ok, journey} <- declared(id),
         {:ok, lock} <- lock(root) do
      case Enum.flat_map(journey.ir["locales"], &refusals(root, lock, id, journey, &1)) do
        [] -> :ok
        refusals -> {:error, "journey #{id}: " <> Enum.join(refusals, "; ")}
      end
    end
  end

  @impl true
  def proves_producer(id, criterion) do
    with {:ok, %{ir: ir}} <- declared(id) do
      if criterion in List.wrap(get_in(ir, ["metadata", "controls"])),
        do: :ok,
        else: {:error, "journey #{id} does not name #{criterion} in its metadata controls"}
    end
  end

  defp declared(id) do
    case Lock.declared() do
      {:ok, %{^id => journey}} ->
        {:ok, journey}

      {:ok, _declared} ->
        {:error, "journey #{id} is not declared by any module in config :ash_journeys"}

      {:error, problems} ->
        {:error, "the declared journeys do not read: " <> Enum.join(problems, "; ")}
    end
  end

  defp lock(root) do
    case Lock.read(root) do
      {:ok, lock} ->
        {:ok, lock}

      {:error, problems} ->
        {:error, "the journeys lock does not read: " <> Enum.join(problems, "; ")}
    end
  end

  defp refusals(root, lock, id, journey, locale) do
    case Lock.verify(root, lock, id, journey, locale) do
      {:ok, _entry, _manifest} -> []
      {:error, refusal, reasons} -> ["#{locale} is #{refusal}: " <> Enum.join(reasons, ", ")]
    end
  end
end
