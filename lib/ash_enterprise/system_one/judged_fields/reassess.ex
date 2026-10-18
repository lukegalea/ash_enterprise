defmodule AshEnterprise.SystemOne.JudgedFields.Reassess do
  @moduledoc """
  The generated `:reassess_judgments` action: the bounded reassessment of
  one record's stale or expired judged facts (S1-53; AC-3's consumer).

  1. Reads the record (the trigger hands over its primary key and tenant).
  2. Recomputes each question's current state digest from the record as
     it is now — never trusting a digest computed before the job ran.
  3. Selects through `AshJudgments.Query.assess/4`, the package's assess
     path, keeping only the reasons a reassessment exists for here:
     `:stale` and `:expired`. A question this record was never assessed on
     (`:no_fact`) is not assessed by a write; that is an explicit act.
  4. Hands at most the resource's `assess_limit` of them to the assessor
     (`config :ash_enterprise, AshEnterprise.SystemOne.JudgedFields,
     assessor: {module, function, extra_args}`, default
     `AshEnterprise.SystemOne.JudgedFields.Assessor.assess/1`), which runs
     the judge, records, bands and materialises.

  Nothing here runs in a read: it is an action, run by the resource's
  AshOban trigger, and every instrument call it causes is a ledger row.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.SystemOne.JudgedFields

  @reassessable [:stale, :expired]

  @impl true
  def run(input, _opts, context) do
    resource = input.resource
    tenant = input.tenant || context.tenant
    id = primary_key_id(input.arguments.primary_key)

    case read_record(resource, id, tenant) do
      nil ->
        {:ok, %{assessed: 0, selected: [], results: %{}}}

      record ->
        selected =
          resource
          |> JudgedFields.fields()
          |> Enum.flat_map(&select(resource, record, &1))
          |> Enum.take(JudgedFields.assess_limit(resource))

        results =
          Map.new(selected, fn {field, reason, state, digest} ->
            {field.name,
             assessor().(%{
               resource: resource,
               record: record,
               field: field,
               reason: reason,
               state: state,
               digest: digest,
               subject: JudgedFields.subject(resource, record.id),
               tenant: tenant
             })}
          end)

        {:ok,
         %{
           assessed: map_size(results),
           selected:
             Enum.map(selected, fn {field, reason, _, _} ->
               %{question: field.name, reason: reason}
             end),
           results: results
         }}
    end
  end

  defp select(resource, record, field) do
    state = JudgedFields.state_input(field, &Map.get(record, &1))
    digest = JudgedFields.state_digest(resource, field, state)
    subject = JudgedFields.subject(resource, record.id)

    JudgedFields.facts_resource()
    |> AshJudgments.Query.assess([subject], field.question_id,
      current_digests: %{subject => digest},
      limit: JudgedFields.assess_limit(resource)
    )
    |> Enum.filter(fn {_subject, reason} -> reason in @reassessable end)
    |> Enum.map(fn {_subject, reason} -> {field, reason, state, digest} end)
  end

  defp read_record(resource, id, tenant) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read_one!(authorize?: false)
  end

  defp primary_key_id(%{"id" => id}), do: id
  defp primary_key_id(%{id: id}), do: id

  defp assessor do
    {m, f, a} =
      :ash_enterprise
      |> Application.get_env(JudgedFields, [])
      |> Keyword.get(:assessor, {AshEnterprise.SystemOne.JudgedFields.Assessor, :assess, []})

    fn request -> apply(m, f, [request | a]) end
  end
end
