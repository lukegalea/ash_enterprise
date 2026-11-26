defmodule AshEnterprise.Provenance.IntegrityTest do
  @moduledoc """
  Integrity anchors on an audit step (ADR 0078, section 7): the recorded
  audit-chain verification decides a step's status — nil when none is
  recorded or the event postdates the verification, `:verified` when the
  verification covered the event and found nothing, `:altered` when it
  found the row changed behind the chain's back. Where a break is and how
  many rows fail stay with the compliance finding: the answer carries a
  status only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.ChainVerifyWorker
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Provenance
  alias AshEnterprise.Repo

  setup do
    admin = tenant!()
    unique = System.unique_integer([:positive])

    reader =
      member!(admin, "Integrity reader #{unique}", [
        {Task, :read, :global},
        {EventLog, :read, :global},
        {User, :read, :global}
      ])

    %{admin: admin, reader: reader, task: Task.capture!("Anchor #{unique}", as(admin))}
  end

  test "no recorded verification means not checked", %{reader: reader, task: task} do
    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    assert is_nil(step(explanation, :was_generated_by).integrity)
  end

  test "a verification the event predates reads verified, and a later event is not checked", %{
    admin: admin,
    reader: reader,
    task: task
  } do
    assert {:ok, _} = ChainVerifyWorker.run()

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    integrity = step(explanation, :was_generated_by).integrity
    assert integrity.anchor == :audit_chain
    assert integrity.status == :verified

    # The status and its verified_at are all the answer learns: no counts, no
    # finding positions, no ids from the evidence artifact.
    refute inspect(explanation) =~ "findings"

    # A write after the verification was never checked: nil, never :verified.
    later = Task.capture!("After the check", as(admin))

    {:ok, %{explanation: later_explanation}} = explain(reader, "task", later.id, "title")

    assert is_nil(step(later_explanation, :was_generated_by).integrity)
  end

  test "a row changed behind the trigger's back reads altered", %{
    admin: admin,
    reader: reader,
    task: task
  } do
    assert {:ok, _} = ChainVerifyWorker.run()

    # The task's own event, quietly changed: the hash no longer verifies, and
    # the next verification files the finding at its sequence.
    quietly_change_record!(admin.tenant, task.id)
    org = admin.tenant

    assert {:ok, outcomes} = ChainVerifyWorker.run()
    assert {^org, findings} = List.keyfind(outcomes, org, 0)
    assert findings > 0

    {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

    integrity = step(explanation, :was_generated_by).integrity
    assert integrity.status == :altered
  end

  # -- Helpers -------------------------------------------------------------

  defp as(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp step(explanation, relation), do: Enum.find(explanation.steps, &(&1.relation == relation))

  # Changes one record's event behind the immutability trigger's back, which
  # the chain's hash catches — `retention_test.exs`'s
  # `quietly_change_first!/2`, pointed at the event this test explains. A
  # jsonb column carries the change, not `action`, whose atom type would
  # refuse to load the tampered row at all.
  defp quietly_change_record!(org, record_id) do
    Repo.query!("ALTER TABLE audit_events DISABLE TRIGGER audit_events_immutable")

    try do
      Repo.query!(
        "UPDATE audit_events SET changed_attributes = changed_attributes || '{\"quietly_changed\": true}'::jsonb " <>
          "WHERE organization_id = $1::uuid AND record_id = $2::uuid",
        [Ecto.UUID.dump!(org), Ecto.UUID.dump!(record_id)]
      )
    after
      Repo.query!("ALTER TABLE audit_events ENABLE TRIGGER audit_events_immutable")
    end
  end
end
