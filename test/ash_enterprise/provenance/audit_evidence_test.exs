defmodule AshEnterprise.Provenance.AuditEvidenceTest do
  @moduledoc """
  The audit explainer's evidence rules over the hot log (ADR 0078): a
  value-granularity answer is one only when the newest recorded write shows the
  value the reader reads now — a write outside the recorded actions answers at
  `:record` granularity with no value and a `:not_recorded` gap — and an
  audited attribute with no recorded write at all says so, while the record
  columns still answer after it.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1, member!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Provenance
  alias AshEnterprise.Repo
  alias AshProvenance.Address

  @value_gap_summary "The newest recorded write of this attribute does not show its current value."
  @no_write_gap_summary "No recorded write of this attribute: its history was purged, or it was written outside the recorded actions."

  setup do
    # The planted event enters the tenant's chain before any bootstrap write,
    # as the archive tests plant theirs.
    org = Ash.UUID.generate()
    unique = System.unique_integer([:positive])

    task = task!(org, "Task #{unique}")
    admin = tenant!(organization_id: org)

    reader =
      member!(admin, "Auditor #{unique}", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    %{admin: admin, org: org, reader: reader, task: task, unique: unique}
  end

  test "a recorded write that does not show the current value says so", %{
    org: org,
    reader: reader,
    task: task,
    unique: unique
  } do
    # A write outside the recorded actions left today's value: the newest
    # event that changed `title` recorded a different one.
    planted = plant_title_event!(org, task, "Old #{unique}", 1)

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    # The event is named, but at record granularity: nothing in the answer
    # says it wrote the value the reader reads.
    generated = step(explanation, :was_generated_by)
    assert generated.activity == "audit_event:" <> to_string(planted)
    assert generated.granularity == :record
    assert generated.value == nil

    assert [gap] =
             Enum.filter(
               explanation.gaps,
               &(&1.kind == :not_recorded and &1.summary == @value_gap_summary)
             )

    assert Address.to_iri(gap.of) ==
             "#{Provenance.base()}/task/#{task.id}#title"

    # The summary never carries either value.
    refute inspect(explanation) =~ "Old #{unique}"
  end

  test "a recorded write that shows the current value answers at value granularity", %{
    org: org,
    reader: reader,
    task: task
  } do
    plant_title_event!(org, task, task.title, 1)

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    generated = step(explanation, :was_generated_by)
    assert generated.granularity == :value
    assert generated.value == {:value, task.title}

    refute Enum.any?(explanation.gaps, &(&1.summary == @value_gap_summary))
  end

  test "an audited attribute with no recorded write says so, and the record columns still answer",
       %{
         reader: reader,
         task: task
       } do
    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    # The gap-only audit answer does not end the dispatch: who created and last
    # modified the row survives (ADR 0023).
    assert Enum.map(explanation.steps, & &1.relation) == [
             :was_attributed_to,
             :was_attributed_to
           ]

    assert [gap] = explanation.gaps
    assert gap.kind == :not_recorded
    assert gap.summary == @no_write_gap_summary
  end

  test "a reader without the audit grant gets no such gap", %{
    admin: admin,
    task: task,
    unique: unique
  } do
    reader = member!(admin, "No audit #{unique}", [{Task, :read, :global}])

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    assert Enum.any?(explanation.steps, &(&1.relation == :was_attributed_to))
    refute Enum.any?(explanation.gaps, &(&1.summary == @no_write_gap_summary))
  end

  # -- Helpers -------------------------------------------------------------

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp step(explanation, relation), do: Enum.find(explanation.steps, &(&1.relation == relation))

  # A real task row, written directly: no audit event of its own, so the one
  # this test plants is the newest that changed `title`.
  defp task!(org, title) do
    owner = Ecto.UUID.dump!(Ash.UUID.generate())

    [[id]] =
      Repo.query!(
        "INSERT INTO canonical_tasks " <>
          "(organization_id, owner_id, owner_type, title, source, created_by_id, modified_by_id) " <>
          "VALUES ($1, $2, 'user', $3, 'capture', $2, $2) RETURNING id",
        [Ecto.UUID.dump!(org), owner, title]
      ).rows

    struct!(Task, id: Ecto.UUID.load!(id), title: title)
  end

  # An event for the task's `title`, `days` old, inserted raw so the chain
  # trigger hashes and links it.
  defp plant_title_event!(org, task, title, days) do
    [[id]] =
      Repo.query!(
        "INSERT INTO audit_events (resource, record_id, changed_attributes, metadata, occurred_at, action, action_type) " <>
          "VALUES ($1, $2, $3::jsonb, $4::jsonb, now() - make_interval(days => $5), 'update', 'update') " <>
          "RETURNING id",
        [
          to_string(Task),
          Ecto.UUID.dump!(task.id),
          %{"title" => title},
          %{"organization_id" => org},
          days
        ]
      ).rows

    Ecto.UUID.cast!(id)
  end
end
