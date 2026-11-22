defmodule AshEnterprise.SystemOne.QuestionProposal.Display do
  @moduledoc """
  What a person confirming a question proposal reads: the proposal's
  `:question_names` and `:questions` calculations, rendered from the
  stored entries. Display only; the entries themselves are what
  `:confirm` re-validates and hashes.

  - `:question_names`: the proposed questions' names, comma-separated.
  - `:questions`: every proposed question in full, one paragraph each:
    its name, the clause it cites and its family; the wording the model
    will be asked; the answers it may give; the criteria for each
    answer; and the state shape the question reads (or none).
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:proposals]

  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, &display(&1.proposals || [], opts[:field]))
  end

  defp display(entries, :question_names), do: Enum.map_join(entries, ", ", & &1["name"])
  defp display(entries, :questions), do: Enum.map_join(entries, "\n\n", &question/1)

  defp question(entry) do
    Enum.join(
      [
        "#{entry["name"]} (clause #{entry["clause_ref"]}, family #{entry["family"]})",
        "Asks: #{entry["instructions"]}",
        "Answers: #{answers(entry)}",
        "Criteria: #{criteria(entry["criteria"])}",
        "State shape: #{state_shape(entry["state_shape"])}"
      ],
      "\n"
    )
  end

  defp answers(entry) do
    case entry["answer_type"] do
      "noul" -> "yes or no"
      "choice" -> "one of " <> Enum.join(entry["options"] || [], ", ")
      "score" -> "a level of " <> Enum.join(entry["options"] || [], ", ")
    end
  end

  defp criteria(criteria) when is_map(criteria) and map_size(criteria) > 0,
    do: Enum.map_join(criteria, "; ", fn {answer, text} -> "#{answer}: #{text}" end)

  defp criteria(_none), do: "none"

  defp state_shape(shape) when is_map(shape) and map_size(shape) > 0, do: Jason.encode!(shape)
  defp state_shape(_none), do: "none, the question reads the subject as it is"
end
