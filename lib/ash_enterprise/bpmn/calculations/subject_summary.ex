defmodule AshEnterprise.Bpmn.Calculations.SubjectSummary do
  @moduledoc """
  What a human task is about, for a person deciding it:

    * `field: :label` — `Morning brief · Mon 12 Oct`, or the subject's kind;
    * `field: :outline` — the brief in one line (`6 events · 08:30–17:30`);
    * `field: :detail` — the morning brief's draft (rendered on read, so a
      shredded event line reads `[shredded]`), or nothing for other kinds.

  The subject is read under the reading actor's policies: a reader who may see
  the task but not its subject sees the kind and nothing more.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Platform.LocalTime

  # The engine records a subject type as `to_string(module)` ("Elixir.…").
  @brief to_string(MorningBrief)

  @impl true
  def init(opts) do
    if opts[:field] in [:label, :outline, :detail],
      do: {:ok, opts},
      else: {:error, "field must be :label, :outline or :detail"}
  end

  @impl true
  def load(_query, _opts, _context),
    do: [:subject_type, :subject_id, :name, instance: [:subject_type, :subject_id]]

  @impl true
  def calculate(tasks, opts, context) do
    tasks = Enum.map(tasks, &subject/1)
    briefs = briefs(tasks, opts[:field], context)
    {:ok, Enum.map(tasks, &value(&1, opts[:field], briefs))}
  end

  # A process task names its subject through its instance (the task's own
  # subject columns are for standalone approvals).
  defp subject(%{subject_type: type, subject_id: id}) when is_binary(type) and not is_nil(id),
    do: %{subject_type: type, subject_id: id}

  defp subject(%{instance: %{subject_type: type, subject_id: id}}),
    do: %{subject_type: type, subject_id: id}

  defp subject(_task), do: %{subject_type: nil, subject_id: nil}

  defp briefs(tasks, field, context) do
    ids = for %{subject_type: @brief, subject_id: id} <- tasks, not is_nil(id), do: id

    if ids == [] do
      %{}
    else
      load =
        case field do
          :detail -> [:draft_text]
          :outline -> [:summary]
          :label -> []
        end

      MorningBrief
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load(load)
      |> Ash.read!(Ash.Context.to_opts(context))
      |> Map.new(&{&1.id, &1})
    end
  end

  defp value(%{subject_type: @brief, subject_id: id}, :label, briefs) do
    case Map.get(briefs, id) do
      nil -> "Morning brief"
      brief -> "Morning brief · #{LocalTime.day(brief.brief_date)}"
    end
  end

  defp value(%{subject_type: @brief, subject_id: id}, :outline, briefs) do
    case Map.get(briefs, id) do
      nil -> nil
      brief -> brief.summary
    end
  end

  defp value(%{subject_type: @brief, subject_id: id}, :detail, briefs) do
    case Map.get(briefs, id) do
      nil -> nil
      brief -> brief.draft_text
    end
  end

  defp value(%{subject_type: type}, :label, _briefs) when is_binary(type) do
    type
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp value(_task, _field, _briefs), do: nil
end
