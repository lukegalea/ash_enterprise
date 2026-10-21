defmodule AshEnterprise.Mdm.ResolutionTest do
  @moduledoc """
  PROD-47: who a person resolved to, and when. SourceIdentity is temporal,
  so scrubbing a golden person to before a merge shows two people, and to
  after it shows one; an unmerge makes them two again. A reader who cannot
  read the person cannot time-travel them either.

  SYNTHETIC data only: `.test` addresses and invented names.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, person!: 3, scope!: 1]

  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Mdm.{ImportBatch, Landing, MatchCandidate, Resolution, SourceIdentity}
  alias AshEnterprise.Mdm.StagedRecord

  setup do
    ctx = tenant!()
    survivor = person!(ctx, "jane.work@example.test", "Jane Work")
    loser = person!(ctx, "jane.home@example.test", "Jane Home")

    # Both identities were resolved a week ago; the merge happens now.
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    identity!(ctx, survivor, "slack:U-jane", week_ago)
    identity!(ctx, loser, "gmail:jane.home", week_ago)

    %{ctx: ctx, survivor: survivor, loser: loser, before_merge: DateTime.add(week_ago, 1, :day)}
  end

  defp opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]
  defp system(ctx), do: [tenant: ctx.tenant, authorize?: false]

  defp identity!(ctx, golden, external_id, as_of) do
    SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: :slack,
        stream: :users,
        external_id: external_id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        asserted_by: :mapping
      },
      system(ctx) ++ [as_of: as_of]
    )
    |> Ash.create!()
  end

  defp merge!(ctx, loser, survivor) do
    loser
    |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: survivor.id}, system(ctx))
    |> Ash.update!()
  end

  defp unmerge!(ctx, loser) do
    Person
    |> Ash.get!(loser.id, system(ctx))
    |> Ash.Changeset.for_update(:mdm_unmerge, %{}, system(ctx))
    |> Ash.update!()
  end

  # What a people sweep leaves behind: a candidate pairing the golden with
  # the staged observation of the other person.
  defp paired!(ctx, golden, other) do
    {:ok, source_record} =
      Landing.land_row(ctx.tenant, "people", %{"email" => to_string(other.email)},
        row_key: "pair-#{System.unique_integer([:positive])}"
      )

    mapping = activate_host_mapping!(draft_host_mapping!(ctx.tenant, []), ctx.tenant, ctx.user)

    batch =
      ImportBatch
      |> Ash.Changeset.for_create(
        :open,
        %{mapping_id: mapping.id, source_slug: "people"},
        system(ctx)
      )
      |> Ash.create!()

    staged =
      StagedRecord
      |> Ash.Changeset.for_create(
        :stage,
        %{
          batch_id: batch.id,
          source_record_id: source_record.id,
          mapped: %{"email" => to_string(other.email), "person_id" => other.id}
        },
        system(ctx)
      )
      |> Ash.create!()

    MatchCandidate
    |> Ash.Changeset.for_create(
      :create,
      %{
        staged_record_id: staged.id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden.id,
        score: Decimal.new("0.95"),
        explanation: %{"rules" => []}
      },
      system(ctx)
    )
    |> Ash.create!()
  end

  defp labels(people), do: Enum.map(people, & &1.label)
  defp external_ids(person), do: person.identities |> Enum.map(& &1.external_id) |> Enum.sort()

  test "before the merge the golden was two people; after it, one", %{
    ctx: ctx,
    survivor: survivor,
    loser: loser,
    before_merge: before_merge
  } do
    merge!(ctx, loser, survivor)

    assert {:ok, history} = Resolution.history(survivor.id, opts(ctx))

    assert [jane_work, jane_home] = Resolution.as_of(history, before_merge, opts(ctx))
    assert jane_work.label == "Jane Work"
    assert external_ids(jane_work) == ["slack:U-jane"]
    assert jane_home.label == "Jane Home"
    assert external_ids(jane_home) == ["gmail:jane.home"]

    assert [now] = Resolution.as_of(history, nil, opts(ctx))
    assert now.label == "Jane Work"
    assert external_ids(now) == ["gmail:jane.home", "slack:U-jane"]

    # The merge is a mark, and landing on it shows the merged state.
    assert [merged] = Enum.filter(history.marks, &(&1.kind == :merged))
    assert merged.description =~ "Jane Home merged into Jane Work"
    assert [_one] = Resolution.as_of(history, merged.at, opts(ctx))

    assert [_two, _people] =
             Resolution.as_of(history, DateTime.add(merged.at, -1, :microsecond), opts(ctx))
  end

  test "an unmerge makes them two again, and the golden's history still shows the merge", %{
    ctx: ctx,
    survivor: survivor,
    loser: loser
  } do
    paired!(ctx, survivor, loser)
    merge!(ctx, loser, survivor)
    unmerge!(ctx, loser)

    assert {:ok, history} = Resolution.history(survivor.id, opts(ctx))
    assert [merged] = Enum.filter(history.marks, &(&1.kind == :merged))
    assert [unmerged] = Enum.filter(history.marks, &(&1.kind == :unmerged))
    assert DateTime.compare(merged.at, unmerged.at) == :lt

    assert ["Jane Work"] = history |> Resolution.as_of(merged.at, opts(ctx)) |> labels()
    assert ["Jane Work", "Jane Home"] = history |> Resolution.as_of(nil, opts(ctx)) |> labels()
  end

  test "the business events of the people involved are context marks", %{
    ctx: ctx,
    survivor: survivor,
    loser: loser
  } do
    previous = Application.get_env(:ash_enterprise, BusinessEvents)

    Application.put_env(:ash_enterprise, BusinessEvents,
      region: :test,
      residency_tag: "test",
      emit?: true
    )

    on_exit(fn -> Application.put_env(:ash_enterprise, BusinessEvents, previous) end)

    owner = %{
      owner_id: ctx.user.id,
      owner_type: :user,
      owning_user_id: ctx.user.id,
      owning_business_unit_id: ctx.user.owning_business_unit_id
    }

    scope = scope!(Ash.UUID.generate())

    conversation =
      Conversation.upsert_from_source!(
        Map.merge(owner, %{
          external_system: "gmail",
          external_id: "conv-#{System.unique_integer([:positive])}",
          subject: "Synthetic thread",
          participants: %{"emails" => [], "person_ids" => [loser.id]},
          erasure_scope_id: scope.id
        }),
        system(ctx)
      )

    Message.upsert_from_source!(
      Map.merge(owner, %{
        external_system: "gmail",
        external_id: "msg-#{System.unique_integer([:positive])}",
        body: "Synthetic body",
        sent_at: DateTime.add(DateTime.utc_now(), -2, :day),
        direction: :inbound,
        conversation_id: conversation.id,
        sender_id: loser.id,
        erasure_scope_id: scope.id
      }),
      system(ctx)
    )

    merge!(ctx, loser, survivor)

    assert {:ok, history} = Resolution.history(survivor.id, opts(ctx))
    assert [arrived] = Enum.filter(history.marks, &(&1.kind == :activity))
    assert arrived.label == "Arrived"
    assert arrived.description == "A message from them arrived"
  end

  test "a reader who cannot read the person cannot time-travel them", %{
    ctx: ctx,
    survivor: survivor,
    loser: loser
  } do
    merge!(ctx, loser, survivor)

    # A steward with every MDM read, but Person is owner-only: someone
    # else's person is not theirs to open, now or then.
    reader =
      member!(ctx, "Steward", [
        {Person, :read, :basic},
        {SourceIdentity, :read, :global},
        {MatchCandidate, :read, :global}
      ])

    assert {:error, :not_found} = Resolution.history(survivor.id, opts(reader))
    assert {:error, :not_found} = Resolution.resolved_at(survivor.id, nil, opts(reader))
    assert {:ok, _} = Resolution.history(survivor.id, opts(ctx))
  end
end
