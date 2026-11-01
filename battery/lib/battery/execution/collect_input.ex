defmodule Battery.Execution.CollectInput do
  @moduledoc """
  The invocation's `collect_input` action: reads the answered task of a `dispatched`
  question and completes the invocation with `complete_external`, the answer as its
  `result`. A cancelled task fails it as `"input_withdrawn"`, one completed without an
  answer as `"input_not_answered"`; a task still open, or a
  row no longer `dispatched`, is `:skipped`. The completion wakes nothing here (the
  battery has no `:step` trigger); the battery takes the run's next step itself.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Battery.Bpmn.HumanTask
  alias Battery.Execution.HumanInput

  @impl true
  def run(input, _opts, _context) do
    id = input.arguments.primary_key["id"]

    case Ash.get(input.resource, id, authorize?: false) do
      {:ok, %{status: :dispatched, effect_system: "human_input"} = row} -> collect(row)
      {:ok, _other} -> {:ok, :skipped}
      {:error, error} -> {:error, error}
    end
  end

  defp collect(row) do
    key = HumanInput.key()

    HumanTask
    |> Ash.Query.filter(subject_id == ^row.id and node_id == ^key)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      %{status: :completed, outcome: "answered", comment: answer} when is_binary(answer) ->
        complete(row, %{outcome: :succeeded, via: "human_task", result: %{"answer" => answer}})

      %{status: :cancelled} ->
        complete(row, failed("input_withdrawn"))

      %{status: :completed} ->
        complete(row, failed("input_not_answered"))

      _open_or_missing ->
        {:ok, :skipped}
    end
  end

  defp failed(code),
    do: %{outcome: :failed, via: "human_task", failure_class: :rejected, error_code: code}

  defp complete(row, input) do
    row
    |> Ash.Changeset.for_update(:complete_external, input)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, done} -> {:ok, done.status}
      {:error, error} -> {:error, error}
    end
  end
end
