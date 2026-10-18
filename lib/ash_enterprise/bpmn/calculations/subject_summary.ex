defmodule AshEnterprise.Bpmn.Calculations.SubjectSummary do
  @moduledoc """
  What a human task is about, for a person deciding it:

    * `field: :label` — `Morning brief · Mon 12 Oct`, `Match · Bea Smith ↔ Bea
      Smyth` (a steward decision's pair), or the subject's kind;
    * `field: :outline` — the brief in one line (`6 events · 08:30–17:30`);
    * `field: :detail` — the morning brief's draft (rendered on read, so a
      shredded event line reads `[shredded]`), or nothing for other kinds;
    * `field: :ref` — the subject as a typed record reference,
      `"<surface key>:<id>"`: the registry surface that shows a record of the
      subject's type (`AshEnterprise.Surfaces.record_surface/1`) and its id.
      Any subject type the registry can show links; others are nil. The
      surface is the polymorphic link target (`link {:record, :subject_ref}`):
      opening it re-reads the subject as the person who clicked.

  The subject is read under the reading actor's policies: a reader who may see
  the task but not its subject sees the kind and nothing more.
  """

  use Ash.Resource.Calculation

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Platform.LocalTime

  # The engine records a subject type as `to_string(module)` ("Elixir.…").
  @brief to_string(MorningBrief)
  @candidate to_string(AshEnterprise.Mdm.MatchCandidate)

  @impl true
  def init(opts) do
    if opts[:field] in [:label, :outline, :detail, :ref],
      do: {:ok, opts},
      else: {:error, "field must be :label, :outline, :detail or :ref"}
  end

  @impl true
  def load(_query, _opts, _context),
    do: [:subject_type, :subject_id, :name, instance: [:subject_type, :subject_id]]

  @impl true
  def calculate(tasks, [field: :ref] = _opts, _context) do
    {:ok, Enum.map(tasks, &(&1 |> subject() |> typed_ref()))}
  end

  def calculate(tasks, opts, context) do
    tasks = Enum.map(tasks, &subject/1)
    briefs = briefs(tasks, opts[:field], context)
    candidates = if opts[:field] == :label, do: candidates(tasks, context), else: %{}
    {:ok, Enum.map(tasks, &value(&1, opts[:field], Map.merge(briefs, candidates)))}
  end

  # A process task names its subject through its instance (the task's own
  # subject columns are for standalone approvals).
  defp subject(%{subject_type: type, subject_id: id}) when is_binary(type) and not is_nil(id),
    do: %{subject_type: type, subject_id: id}

  defp subject(%{instance: %{subject_type: type, subject_id: id}}),
    do: %{subject_type: type, subject_id: id}

  defp subject(_task), do: %{subject_type: nil, subject_id: nil}

  # No read: the reference names the record, and whoever follows it reads it
  # under their own policies. A type the registry cannot show is no link.
  defp typed_ref(%{subject_type: "Elixir." <> _ = type, subject_id: id}) when not is_nil(id) do
    with {:ok, resource} <- resource(type),
         %{key: key} <- AshEnterprise.Surfaces.record_surface(resource) do
      "#{key}:#{id}"
    else
      _ -> nil
    end
  end

  defp typed_ref(_subject), do: nil

  # Subject types are written by the engine from a module name; only a module
  # that already exists is a resource worth naming.
  defp resource(type) do
    {:ok, String.to_existing_atom(type)}
  rescue
    ArgumentError -> :error
  end

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

  # A steward-decision task names the pair it decides, as the reader may see
  # it: the staged row and the golden are read under their own policies, so
  # a golden the reader may not read leaves its half generic.
  defp candidates(tasks, context) do
    ids = for %{subject_type: @candidate, subject_id: id} <- tasks, not is_nil(id), do: id

    if ids == [] do
      %{}
    else
      AshEnterprise.Mdm.MatchCandidate
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.load([:staged_label, :golden_label])
      |> Ash.read!(Ash.Context.to_opts(context))
      |> Map.new(&{&1.id, &1})
    end
  end

  defp value(%{subject_type: @candidate, subject_id: id}, :label, found) do
    case Map.get(found, id) do
      %{staged_label: staged, golden_label: golden} when is_binary(golden) and golden != "" ->
        "Match · #{staged} ↔ #{golden}"

      %{staged_label: staged} ->
        "Match · #{staged}"

      nil ->
        "Match candidate"
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
