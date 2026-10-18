defmodule AshEnterprise.SystemOne.JudgedFields.MaintainDigests do
  @moduledoc """
  Keeps a record's `judgment_digests` current, in the record's own
  transaction, and enqueues reassessment when a write turns a fact stale
  (S1-53 §7.4 normative 2; AC-3).

  Added to every create and update of a resource using
  `AshEnterprise.SystemOne.JudgedFields`. Per declared question:

  1. **Before the write**, the digest of the state the question's judge
     would see is computed from the record's projection fields as they
     will be stored, and set on `judgment_digests`.
  2. **After the write**, when some question's digest moved, the facts
     about the record for those questions are read: if any current fact
     recorded a different digest, that fact now reads stale, and the
     resource's reassess trigger is enqueued — in the same transaction, so
     a rolled-back write enqueues nothing.

  An update that changes no projection field does nothing at all: no
  digest work, no facts read, nothing enqueued. That is also why it stays
  atomic; an update that does change a projection field cannot be,
  because the digest is a SHA-256 over canonical JSON computed here.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.SystemOne.JudgedFields

  @impl true
  def change(changeset, _opts, _context) do
    fields = JudgedFields.fields(changeset.resource)

    if fields == [] or not touches_projection?(changeset, fields) do
      changeset
    else
      changeset
      |> Ash.Changeset.before_action(&put_digests(&1, fields))
      |> Ash.Changeset.after_action(&enqueue_if_stale(&1, &2, fields))
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    fields = JudgedFields.fields(changeset.resource)

    if fields == [] or not touches_projection?(changeset, fields) do
      :ok
    else
      {:not_atomic,
       "a judged question's projection field changes: its state digest is computed in Elixir"}
    end
  end

  # A create always establishes the digests; an update only when one of
  # the projection fields is part of the write.
  defp touches_projection?(%{action_type: :create}, _fields), do: true

  defp touches_projection?(changeset, fields) do
    fields
    |> Enum.flat_map(& &1.projection)
    |> Enum.uniq()
    |> Enum.any?(&Ash.Changeset.changing_attribute?(changeset, String.to_existing_atom(&1)))
  end

  defp put_digests(changeset, fields) do
    digests =
      Map.new(fields, fn field ->
        state = JudgedFields.state_input(field, &Ash.Changeset.get_attribute(changeset, &1))
        {field.question_id, JudgedFields.state_digest(changeset.resource, field, state)}
      end)

    Ash.Changeset.force_change_attribute(changeset, JudgedFields.digest_attribute(), digests)
  end

  defp enqueue_if_stale(changeset, record, fields) do
    digests = Map.get(record, JudgedFields.digest_attribute()) || %{}
    previous = previous_digests(changeset)

    moved =
      fields
      |> Enum.map(& &1.question_id)
      |> Enum.filter(&(Map.get(previous, &1) != Map.get(digests, &1)))

    if moved != [] and could_have_facts?(changeset) and stale_fact?(record, moved, digests) do
      AshOban.run_trigger(record, JudgedFields.reassess_trigger(changeset.resource),
        tenant: changeset.tenant,
        unique: [period: :infinity, keys: [:primary_key], states: :incomplete]
      )
    end

    {:ok, record}
  end

  # A plain create is a new record: no fact can be about it yet. An upsert
  # may land on an existing record, so it counts as possibly changed.
  defp could_have_facts?(%{action_type: :create, action: action}), do: action.upsert? == true
  defp could_have_facts?(_changeset), do: true

  defp previous_digests(%{action_type: :update, data: data}),
    do: Map.get(data, JudgedFields.digest_attribute()) || %{}

  defp previous_digests(_changeset), do: %{}

  # The machinery read of the record's own facts, inside its own write:
  # nothing here is returned to a caller, only whether a fact went stale.
  defp stale_fact?(record, question_ids, digests) do
    subject_type = JudgedFields.subject_type(record.__struct__)
    subject_id = to_string(record.id)

    JudgedFields.facts_resource()
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^subject_id and
        predicate in ^question_ids and not is_nil(subject_state_digest)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.any?(&(&1.subject_state_digest != Map.get(digests, &1.predicate)))
  end
end
