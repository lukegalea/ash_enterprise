defmodule AshEnterprise.Bpmn.Calculations.ReviewPacket do
  @moduledoc """
  One section of an invocation approval's review packet
  (`AshEnterprise.Execution.ReviewPacket`), as the text a reviewer reads beside the
  task. `field:` names the section:

    * `:target` — `Credential.activate_credential · edit, reaches outside, approval four_eyes`;
    * `:arguments` — one line per input, named and typed by the target's schema;
    * `:digest` — the approval digest the decision binds;
    * `:currency` — `Current`, `Stale: subject_changed`, `Unknown: …`, `Decided: ready`;
    * `:evidence` — references (`Credential:<id>@3`, `run:<id>`), not contents, and
      `Unknown: …` when the trace could not be read whole;
    * `:decision` — each decision entry with its matched rules, `No decision was
      evaluated.` only when the decision records were read and hold none, `Unknown: …`
      otherwise;
    * `:due` — when the task is due and when the approval window closes;
    * `:escalation` — what the engine recorded about escalating the task;
    * `:questions` — an approver's questions and the requester's answers.

  Nil for a task that is not an invocation's approval task. The packet is read as the
  reader, so what they may not read says so; nothing unread reads as current or empty.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Execution.ReviewPacket
  alias AshEnterprise.Platform.LocalTime

  @fields [
    :target,
    :arguments,
    :digest,
    :currency,
    :evidence,
    :decision,
    :due,
    :escalation,
    :questions
  ]

  @impl true
  def init(opts) do
    if opts[:field] in @fields,
      do: {:ok, opts},
      else: {:error, "field must be one of #{Enum.map_join(@fields, ", ", &inspect/1)}"}
  end

  @impl true
  def load(_query, _opts, _context), do: ReviewPacket.task_fields()

  @impl true
  def calculate(tasks, opts, context) do
    section = section(opts[:field])
    read = Ash.Context.to_opts(context)

    {:ok,
     Enum.map(tasks, fn task ->
       case ReviewPacket.build(task, read, [section]) do
         nil -> nil
         packet -> render(section, Map.fetch!(packet, section))
       end
     end)}
  end

  defp section(:decision), do: :decisions
  defp section(field), do: field

  @unreadable "You may not read the request this task is about."

  @doc false
  @spec render(atom(), term()) :: String.t() | nil
  def render(_section, :unreadable), do: @unreadable
  def render(:arguments, :erased), do: "Erased."

  def render(:target, %{name: name, effect: effect}) do
    case describe_effect(effect) do
      "" -> name
      described -> "#{name} · #{described}"
    end
  end

  def render(:arguments, {:ok, []}), do: "None."

  def render(:arguments, {:ok, arguments}) do
    Enum.map_join(arguments, "\n", fn argument ->
      "#{argument.name}#{typed(argument.type)}: #{value(argument.value)}"
    end)
  end

  def render(:digest, nil), do: "Unknown: nothing is bound."
  def render(:digest, digest), do: digest

  def render(:currency, {:current, nil}), do: "Current: approving decides what was asked."
  def render(:currency, {:stale, reason}), do: "Stale: #{reason}"
  def render(:currency, {:decided, status}), do: "Decided: #{status}"
  def render(:currency, {:unknown, why}), do: "Unknown: #{unknown(why)}"

  def render(:evidence, {:ok, []}), do: "None recorded."
  def render(:evidence, {:ok, refs}), do: Enum.join(refs, "\n")

  def render(:evidence, {:incomplete, refs, why}),
    do: Enum.join(refs ++ ["Unknown: #{incomplete(why)}"], "\n")

  def render(:decisions, {:ok, []}), do: "No decision was evaluated."
  def render(:decisions, {:ok, decisions}), do: decision_lines(decisions)

  def render(:decisions, {:incomplete, decisions, why}),
    do:
      Enum.join(
        Enum.reject([decision_lines(decisions), "Unknown: #{incomplete(why)}"], &(&1 == "")),
        "\n"
      )

  def render(:due, %{due_at: due_at, expires_at: expires_at}) do
    Enum.join(
      [
        "Due #{if due_at, do: LocalTime.stamp(due_at), else: "whenever"}",
        if(expires_at, do: "approval window closes #{LocalTime.stamp(expires_at)}")
      ]
      |> Enum.reject(&is_nil/1),
      "; "
    )
  end

  def render(:escalation, []), do: "Not escalated."

  def render(:escalation, events) do
    Enum.map_join(events, "\n", fn event ->
      "#{escalation(event.kind)} #{LocalTime.stamp(event.at)}"
    end)
  end

  def render(:questions, []), do: nil

  def render(:questions, questions) do
    Enum.map_join(questions, "\n", fn question ->
      "Asked #{LocalTime.stamp(question.asked_at)}: #{question.question}\n" <> answered(question)
    end)
  end

  defp answered(%{answer: answer} = question) when is_binary(answer),
    do: "Answered #{LocalTime.stamp(question.answered_at)}: #{answer}"

  defp answered(%{due_at: %DateTime{} = due_at}),
    do: "Waiting for the requester's answer, due #{LocalTime.stamp(due_at)}"

  defp answered(_waiting), do: "Waiting for the requester's answer"

  # A JSON Schema type: `"string"`, or `["string", "null"]` for one that may be empty.
  defp typed(types) when is_list(types) do
    case Enum.reject(types, &(&1 == "null")) do
      [] -> ""
      kept -> " (#{Enum.join(kept, " or ")}#{if "null" in types, do: ", optional"})"
    end
  end

  defp typed(nil), do: ""
  defp typed(type), do: " (#{type})"

  defp describe_effect(effect) when is_map(effect) do
    get = fn key -> Map.get(effect, key) || Map.get(effect, to_string(key)) end

    [
      get.(:kind) && to_string(get.(:kind)),
      get.(:open_world?) == true && "reaches outside",
      get.(:destructive?) == true && "destructive",
      get.(:approval) && "approval #{get.(:approval)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp describe_effect(_effect), do: ""

  defp value(:sensitive), do: "[sensitive]"
  defp value(nil), do: "—"
  defp value(value) when is_binary(value), do: value

  defp value(value) when is_number(value) or is_boolean(value) or is_atom(value),
    do: to_string(value)

  defp value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _not_json} -> inspect(value)
    end
  end

  defp unknown(:unreadable), do: "you may not read the request."
  defp unknown(:unbound), do: "nothing is bound to approve."
  defp unknown(:unchecked), do: "the binding could not be checked."
  defp unknown(other), do: to_string(other)

  defp escalation(:escalated), do: "Escalated"
  defp escalation(:no_handler), do: "Due for escalation, with nobody to escalate to,"
  defp escalation(:failed), do: "Escalation failed"

  defp decision_lines(decisions) do
    Enum.map_join(decisions, "\n", fn decision ->
      Enum.join(Enum.reject([decision.summary, decision.definition_ref], &is_nil/1), " · ")
    end)
  end

  defp incomplete(:no_correlation),
    do: "the request carries no correlation id, so what it rests on cannot be found."

  defp incomplete(:unread), do: "the request's history could not be read."

  defp incomplete({:unread, sources}),
    do: "#{Enum.map_join(sources, ", ", &to_string/1)} could not be read in full."

  defp incomplete(other), do: inspect(other)
end
