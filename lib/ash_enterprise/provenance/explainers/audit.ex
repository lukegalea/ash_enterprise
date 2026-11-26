defmodule AshEnterprise.Provenance.Explainers.Audit do
  @moduledoc """
  The audit explainer (ADR 0078, section 4): the newest event that changed the
  attribute `was_generated_by` its action, read from the hot log and then the
  archive, as the reader.

  A decrypting calculation over sealed content — `AshEnterprise.Erasure.Calculations.Unseal`
  or the cloak's Decrypt calculation — is answered through the sealed
  attribute its option names: the calculation is how the reader reads it, but what
  wrote it is the sealed column's event.

  A secured column (ADR 0073) passes at every granularity: every secured column
  is `sensitive?`, so the log holds nothing of its value, and "this column
  changed at this time" is itself what the column's grant withholds (ADR 0078,
  section 6). A reader without the audit grant gets no answer either — the log
  read is the reader's own, and a Forbidden read passes, so the record columns
  answer at record granularity instead.

  A read that fails for any other reason is a `:failed` gap, never "nothing
  happened"; an archive read that fails is `:archived`.
  """

  @behaviour AshEnterprise.Provenance.Explainer

  alias AshEnterprise.Audit
  alias AshEnterprise.Erasure.Calculations.Unseal
  alias AshEnterprise.Provenance.{Explainer, Labels}
  alias AshProvenance.{EntityRef, Gap, Step}

  # ADR 0080: the execution context a write ran in, mapped once. Anything the
  # metadata does not name is "not recorded", never live.
  @execution_contexts %{
    "live" => :live,
    "scenario" => :scenario,
    "eval" => :eval,
    "shadow" => :shadow
  }

  @impl true
  def explain(%{field: nil}, _ctx), do: :pass

  def explain(%{resource: resource, field: field} = subject, ctx) do
    cond do
      Explainer.secured?(resource, field) ->
        :pass

      attribute = Ash.Resource.Info.attribute(resource, field) ->
        attribute_answer(attribute, subject, ctx)

      calculation = Ash.Resource.Info.calculation(resource, field) ->
        case unseal_attribute(calculation, resource) do
          {:ok, attribute} -> attribute_answer(attribute, subject, ctx)
          :pass -> :pass
        end

      true ->
        :pass
    end
  end

  # The sealed attribute a decrypting calculation reads for the reader: what
  # wrote it is the sealed column's event, not the calculation's. Erasure's
  # `Unseal` and the cloak's `Decrypt` are the two forms that take — the
  # sealed column is this deployment's `encrypted_*` attribute either way.
  # Any other calculation was the derived explainer's to answer or to pass on.
  defp unseal_attribute(%{calculation: {Unseal, opts}}, resource) do
    sealed_attribute(opts[:field], resource)
  end

  defp unseal_attribute(%{calculation: {AshCloak.Calculations.Decrypt, opts}}, resource) do
    sealed_attribute(opts[:field], resource)
  end

  defp unseal_attribute(_calculation, _resource), do: :pass

  defp sealed_attribute(nil, _resource), do: :pass

  defp sealed_attribute(field, resource) do
    case Ash.Resource.Info.attribute(resource, field) do
      nil -> :pass
      attribute -> {:ok, attribute}
    end
  end

  defp attribute_answer(attribute, subject, ctx) do
    case read_hot(subject, attribute, ctx) do
      {:ok, event} when not is_nil(event) ->
        {:ok, answer(event, subject, attribute, ctx)}

      {:ok, nil} ->
        # Nothing in the hot log: the newest write may have left it already.
        case read_archived(subject, attribute, ctx) do
          {:ok, nil} ->
            # No event in either table changed this attribute.
            :pass

          {:ok, event} ->
            {:ok, answer(event, subject, attribute, ctx)}

          {:error, %Ash.Error.Forbidden{}} ->
            :pass

          {:error, _other} ->
            {:ok, gap_answer(:archived, subject)}
        end

      # A reader who may not read the log learns nothing from it.
      {:error, %Ash.Error.Forbidden{}} ->
        :pass

      {:error, _other} ->
        {:ok, gap_answer(:failed, subject)}
    end
  end

  defp read_hot(subject, attribute, ctx) do
    Audit.latest_event_for_record(
      to_string(subject.resource),
      record_id(subject),
      Atom.to_string(attribute.name),
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp read_archived(subject, attribute, ctx) do
    Audit.latest_archived_event_for_record(
      to_string(subject.resource),
      record_id(subject),
      Atom.to_string(attribute.name),
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp record_id(subject) do
    subject.record
    |> Map.get(List.first(Ash.Resource.Info.primary_key(subject.resource)))
  end

  # -- The answer ---------------------------------------------------------

  defp answer(event, subject, attribute, ctx) do
    activity = "audit_event:" <> to_string(event.id)
    occurred_at = event.occurred_at
    metadata = event.metadata || %{}

    # Record granularity when the evidence is no finer than the record: the
    # source attribute was redacted in the log, the field the reader asked
    # about is itself sensitive (an Unseal calculation over a sealed column,
    # say), or the value has been shredded since the write — its recorded
    # ciphertext is unreadable, and only "this event changed it" remains.
    granularity =
      if attribute.sensitive? or Explainer.sensitive?(subject.resource, subject.field) or
           AshEnterprise.Erasure.Shredded.shredded?(subject.value) do
        :record
      else
        :value
      end

    # The anchor the step's record sits on (ADR 0078, section 7), read once
    # per explain call: nil means "not checked", never "verified".
    {integrity, cache} = integrity_of(event, ctx)

    generated_by =
      Step.new!(
        relation: :was_generated_by,
        entity: subject.address,
        activity: activity,
        at: occurred_at,
        granularity: granularity,
        summary: summary(event),
        execution_context: execution_context(event),
        integrity: integrity,
        value:
          if(granularity == :value,
            do: Explainer.render_value(subject.resource, subject.field, subject.value),
            else: nil
          )
      )

    # Agents are mapped once (ADR 0078, section 2): the activity was
    # associated with the actor it ran as, and whoever ran it for someone
    # else acted on their behalf.
    {associated_with, behalf, used, agent_gaps} =
      agents(event, subject, metadata, activity, occurred_at, granularity, ctx)

    %{
      steps: [generated_by] ++ associated_with ++ behalf ++ used,
      gaps: agent_gaps,
      antecedents: [],
      correlation_ids: %{activity => correlation_id(event)},
      cache: cache
    }
  end

  # The verification read is memoized in the walk's cache; what it returns
  # beside it must reach the walk, so the next audit step reads nothing.
  defp integrity_of(event, ctx) do
    {verification, cache} = AshEnterprise.Provenance.Integrity.verification(ctx)
    {AshEnterprise.Provenance.Integrity.step_integrity(event, verification), cache}
  end

  # -- Agents --------------------------------------------------------------

  defp agents(event, subject, metadata, activity, at, granularity, ctx) do
    cond do
      # `Correlation.audit_metadata/1` writes the keys it has and drops the
      # rest, so absence reads as nil, and `nil and ...` is no boolean.
      is_binary(metadata["impersonator_id"]) ->
        impersonated(subject, event.user_id, metadata, activity, at, granularity, ctx)

      is_binary(metadata["automation_principal"]) and is_binary(metadata["on_behalf_of_id"]) ->
        automation(event, subject, metadata, at, granularity, ctx)

      true ->
        plain(event, subject, activity, at, granularity, ctx)
    end
  end

  # A person's own write, or a system actor's, whose name `Labels` renders.
  defp plain(event, subject, activity, at, granularity, ctx) do
    case Labels.agent_label(event, ctx) do
      {:ok, label} ->
        {[associated(activity, label, at, granularity)], [], [], []}

      :not_recorded ->
        {[], [], [], [Gap.new!(kind: :not_recorded, of: subject.address)]}
    end
  end

  # Impersonation (ADR 0023): the activity ran with the subject's authority —
  # so it was associated with the subject, the event's user — and the operator
  # at the keyboard acted for them. Both named only as far as the reader may
  # read; a subject no user row records cannot be named, and nothing acts on
  # behalf of a nobody.
  defp impersonated(subject, user_id, metadata, activity, at, granularity, ctx) do
    subject_label = Labels.user_label(user_id, ctx)
    operator_label = Labels.user_label(metadata["impersonator_id"], ctx)

    {associated_with, gaps} =
      case subject_label do
        {:ok, label} ->
          {[associated(activity, label, at, granularity)], []}

        :not_recorded ->
          {[], [Gap.new!(kind: :not_recorded, of: subject.address)]}
      end

    behalf =
      case {subject_label, operator_label} do
        {{:ok, on_behalf_of}, {:ok, agent_label}} ->
          [
            Step.new!(
              relation: :acted_on_behalf_of,
              agent_label: agent_label,
              on_behalf_of: on_behalf_of,
              at: at,
              granularity: granularity
            )
          ]

        _one_side_not_recorded ->
          []
      end

    {associated_with, behalf, [], gaps}
  end

  # An automation principal acting for a person (ADR 0043): the principal was
  # associated with the activity, and acted on the person's behalf — the
  # person named only through `Labels`, "a person" when the reader may not
  # read them.
  #
  # A recipe step (ADR 0069) names what ran it: the dispatch is the step's
  # activity when the reader may read it, and the standing grant the step ran
  # under is `used`. An id the metadata carries whose row cannot be read is
  # one unreadable gap, and the id appears nowhere in the answer. The person
  # who caused the triggering event (`Dispatch.caused_by_id`) is never an
  # agent of the step: nothing here reads it (ADR 0069).
  defp automation(event, subject, metadata, at, granularity, ctx) do
    principal_label = Labels.agent_label(event, ctx)
    person_label = Labels.user_label(metadata["on_behalf_of_id"], ctx)
    {dispatch_ref, used, unreadable} = recipe(metadata, ctx)

    {associated_with, gaps} =
      case principal_label do
        {:ok, label} ->
          {[associated("audit_event:" <> to_string(event.id), label, at, granularity)], []}

        :not_recorded ->
          {[], [Gap.new!(kind: :not_recorded, of: subject.address)]}
      end

    gaps =
      gaps ++
        if unreadable, do: [Gap.new!(kind: :unreadable, of: subject.address)], else: []

    behalf =
      behalf_step(principal_label, person_label, dispatch_ref, at, granularity)

    {associated_with, behalf, used, gaps}
  end

  # The recipe the step ran under, read as the reader: the dispatch's
  # reference when it may be read, the grant `used` when both may be, and
  # whether an id the metadata carries names a row the reader cannot read.
  defp recipe(metadata, ctx) do
    dispatch =
      read_id(metadata["recipe_dispatch_id"], &AshEnterprise.Bpmn.get_dispatch(&1, read_as(ctx)))

    grant =
      read_id(
        metadata["recipe_grant_id"],
        &AshEnterprise.Security.get_agent_start_grant(&1, read_as(ctx))
      )

    dispatch_ref =
      case dispatch do
        {:ok, dispatch} -> "dispatch:" <> to_string(dispatch.id)
        _unreadable_or_absent -> nil
      end

    used =
      case {dispatch, grant} do
        {{:ok, dispatch}, {:ok, grant}} ->
          [
            Step.new!(
              relation: :used,
              entity: EntityRef.new!(resource: "agent_start_grant", id: grant.id),
              activity: "dispatch:" <> to_string(dispatch.id),
              granularity: :record,
              summary: "standing grant"
            )
          ]

        _not_both_readable ->
          []
      end

    unreadable = recipe_unreadable?(metadata, {dispatch, grant})

    {dispatch_ref, used, unreadable}
  end

  defp behalf_step(principal_label, person_label, dispatch_ref, at, granularity) do
    case {principal_label, person_label} do
      {{:ok, agent_label}, {:ok, on_behalf_of}} ->
        [
          Step.new!(
            relation: :acted_on_behalf_of,
            agent_label: agent_label,
            on_behalf_of: on_behalf_of,
            activity: dispatch_ref,
            at: at,
            granularity: granularity
          )
        ]

      _one_side_not_recorded ->
        []
    end
  end

  defp associated(activity, label, at, granularity) do
    Step.new!(
      relation: :was_associated_with,
      activity: activity,
      agent_label: label,
      at: at,
      granularity: granularity
    )
  end

  # `:absent` when the metadata carries no id; `:ok` or `:unreadable` when it
  # does. Only a present id can make a row unreadable.
  defp read_id(nil, _read), do: :absent

  defp read_id(id, read) do
    case read.(id) do
      {:ok, row} when not is_nil(row) -> {:ok, row}
      _forbidden_or_not_found -> :unreadable
    end
  end

  defp recipe_unreadable?(metadata, reads) do
    unreadable?(metadata["recipe_dispatch_id"], elem(reads, 0)) or
      unreadable?(metadata["recipe_grant_id"], elem(reads, 1))
  end

  defp unreadable?(nil, _read), do: false
  defp unreadable?(_id, :unreadable), do: true
  defp unreadable?(_id, _read), do: false

  defp read_as(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  defp gap_answer(kind, subject) do
    %{
      steps: [],
      gaps: [Gap.new!(kind: kind, of: subject.address)],
      antecedents: [],
      correlation_ids: %{}
    }
  end

  # Structural only: which action type ran, never its arguments or messages.
  defp summary(event), do: "#{event.action_type} #{event.action}"

  defp execution_context(event) do
    @execution_contexts[(event.metadata || %{})["execution_context"]]
  end

  # The hot log lifts the correlation id into a column; the archive keeps it in
  # the metadata it was stamped from. Same fact, one reader.
  defp correlation_id(event),
    do: Map.get(event, :correlation_id) || (event.metadata || %{})["correlation_id"]
end
