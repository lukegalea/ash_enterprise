defmodule AshEnterprise.AgentSpike.S2SealedFieldsInAuditTest do
  @moduledoc """
  Spike S2: what the audit log keeps of sealed content, and of columns
  derived from it.

  **Reading tested.** Content fields (arguments, results, transcript parts)
  are sealed under the subject's erasure scope. The plan relies on the audit
  wrapper recording only ciphertext (or nil) for them, so a shred makes the
  log unreadable without rewriting a row; and it forbids any derived
  plaintext column, because the wrapper records every changed attribute.

  **Result: holds, and the rule against derived columns is necessary.** On
  `AshEnterprise.Canonical.Task` (sealed `commitment` and `evidence`,
  audited): no event row carries the plaintext; `changed_attributes` holds
  the `encrypted_*` ciphertext. A value derived from sealed content and
  force-set on an ordinary attribute *is* recorded in plaintext, outside any
  key, which is why the plan allows no derived plaintext column. A
  `sensitive?` attribute is recorded as nil (`Canonical.Person.name`), the
  one escape hatch for a column that must exist. Digest columns are
  therefore HMACs under the scope's key, never plain hashes of content.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, scope!: 0, person!: 3]

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.SystemActor

  @commitment "Send Dr. Avery the SYNTHETIC lab results for bed 4"
  @evidence "I will send Dr. Avery the SYNTHETIC lab results by noon"

  defp events(id) do
    EventLog
    |> Ash.Query.filter(record_id == ^id)
    |> Ash.read!(authorize?: false)
  end

  defp recorded(event) do
    Jason.encode!(%{
      data: event.data,
      changed_attributes: event.changed_attributes,
      metadata: event.metadata
    })
  end

  defp propose!(ctx) do
    Task
    |> Ash.Changeset.for_create(
      :propose,
      %{
        commitment: @commitment,
        evidence: @evidence,
        source: "test",
        erasure_scope_id: scope!().id,
        proposer: "spike/1",
        instrument: "deterministic",
        owner_id: ctx.user.id,
        owning_user_id: ctx.user.id,
        owning_business_unit_id: ctx.user.owning_business_unit_id
      },
      actor: SystemActor.proposer(),
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  test "sealed fields reach the audit log as ciphertext only" do
    ctx = tenant!()
    task = propose!(ctx)

    [created] = events(task.id)
    refute recorded(created) =~ "SYNTHETIC"
    refute recorded(created) =~ "Dr. Avery"

    changed = created.changed_attributes
    assert is_binary(changed["encrypted_commitment"] || changed[:encrypted_commitment])
    assert is_binary(changed["encrypted_evidence"] || changed[:encrypted_evidence])

    # The row itself decrypts for a reader; the log never held the words.
    assert Ash.get!(Task, task.id, tenant: ctx.tenant, authorize?: false).commitment ==
             @commitment
  end

  test "a value derived from sealed content and stored in an ordinary column is recorded in plaintext" do
    ctx = tenant!()
    task = propose!(ctx)
    derived = "Derived: " <> @commitment

    task
    |> Ash.Changeset.for_update(:dismiss, %{},
      actor: ctx.actor,
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :title, derived))
    |> Ash.update!()

    leaked = Enum.filter(events(task.id), &(recorded(&1) =~ "SYNTHETIC"))

    # Negative result, asserted on purpose: the wrapper records every changed
    # attribute, so the derived copy sits in the log outside any erasure key.
    assert [event] = leaked
    assert event.action in [:dismiss, "dismiss"]
  end

  test "a sensitive attribute is recorded as nil" do
    ctx = tenant!()

    person =
      person!(ctx, "spike-#{System.unique_integer([:positive])}@example.test", "Avery SYNTHETIC")

    [created | _] = events(person.id)
    refute recorded(created) =~ "Avery SYNTHETIC"
    # `name` was an input, so the wrapper records it under `data` (not
    # `changed_attributes`), with the key kept and the value redacted.
    data = created.data
    assert Map.has_key?(data, "name") or Map.has_key?(data, :name)
    assert is_nil(data["name"] || data[:name])
  end
end
