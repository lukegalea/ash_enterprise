defmodule AshEnterprise.Provenance.ArchiveTest do
  @moduledoc """
  The archive (ADR 0078, section 3, `:archived` gap's neighbour): an event
  older than ninety days moved to `AshEnterprise.Audit.ArchivedEvent` still
  answers, read under the same grant as the hot log. A reader without the
  audit grant gets no audit step from the archive either.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1, member!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.{EventLog, Retention}
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Provenance
  alias AshEnterprise.Repo

  setup do
    # The tenant does not exist yet: the planted event enters its chain before
    # any bootstrap write, so it is the head of the leading run of old events
    # the retention move takes (a tenant's own bootstrap writes are young and
    # sit at the head of a fresh chain, blocking every later old row).
    org = Ash.UUID.generate()
    unique = System.unique_integer([:positive])

    task = task!(org, "Archive #{unique}")
    planted = plant_title_event!(org, task, "Written long ago", 120)

    admin = tenant!(organization_id: org)

    reader =
      member!(admin, "Archived reader #{unique}", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    %{admin: admin, reader: reader, task: task, planted: planted}
  end

  test "an event that left the hot log still answers, from the archive", %{
    admin: admin,
    reader: reader,
    task: task,
    planted: planted
  } do
    assert {:ok, %{audit: steps}} = Retention.archive()

    step = Enum.find(steps, &match?({_, %AshEnterprise.Audit.ArchiveRun{}}, &1))
    assert {:archived, run} = step
    assert run.chain_organization_id == admin.tenant

    refute hot?(admin.tenant, planted)
    assert archived?(admin.tenant, planted)

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    # The newest event that changed `title` is the archived one now: the step
    # names it, read under the same grant as the hot log. The value beside the
    # step is the title as the reader reads it today.
    generated = step(explanation, :was_generated_by)
    assert generated.activity == "audit_event:" <> to_string(planted)
    assert generated.granularity == :value
    assert generated.value == {:value, task.title}
  end

  test "a reader without the audit grant gets no audit step from the archive either", %{
    admin: admin,
    task: task
  } do
    assert {:ok, _} = Retention.archive()

    reader =
      member!(admin, "No audit #{System.unique_integer([:positive])}", [
        {Task, :read, :global}
      ])

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    refute Enum.any?(
             explanation.steps,
             &(&1.relation in [:was_generated_by, :was_associated_with])
           )

    # The record columns still answer: who created the row survives the
    # retention window (ADR 0023).
    assert Enum.any?(explanation.steps, &(&1.relation == :was_attributed_to))
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

  # An event for the task's `title`, `days` old, inserted as the retention
  # tests insert theirs: raw, so the chain trigger hashes and links it.
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

  defp hot?(org, id) do
    count("audit_events", org, id) > 0
  end

  defp archived?(org, id) do
    count("audit_event_archive", org, id) > 0
  end

  defp count(table, org, id) do
    [[n]] =
      Repo.query!(
        "SELECT count(*) FROM #{table} WHERE organization_id = $1::uuid AND id = $2::uuid",
        [Ecto.UUID.dump!(org), Ecto.UUID.dump!(id)]
      ).rows

    n
  end
end
