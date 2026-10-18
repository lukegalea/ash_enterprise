defmodule AshEnterprise.Mdm.PeopleTest do
  @moduledoc """
  PROD-9: the same human across Gmail, Calendar and Slack. Two sources
  produce two Person rows for one person (a work address in Slack and
  Calendar, a home address in Gmail); the people sweep lands them, admits
  the same-address sightings automatically, proposes the pair for review,
  and a steward's confirm merges them so their meetings, messages and
  conversations follow. Unmerge restores; replay is deterministic; namesakes
  with nothing in common stay apart.

  SYNTHETIC data only: every address is on a `.test` domain and every name is
  invented.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, person!: 3, scope!: 1]

  require Ash.Query

  alias AshEnterprise.Agents.Today

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    Conversation,
    ConversationParticipant,
    EventAttendee,
    Message,
    Person
  }

  alias AshEnterprise.Mdm.{MatchCandidate, People, SourceIdentity, StagedRecord}
  alias AshEnterprise.Mdm.People.{Pipeline, Seed, SweepWorker}
  alias AshEnterprise.Platform.Seeder

  setup do
    platform = Seeder.seed_platform_organization()
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform.id)

    ctx = tenant!()
    Seed.seed!(ctx.tenant, ctx.actor)

    Map.merge(ctx, %{
      slack: scope!(Ash.UUID.generate()),
      calendar: scope!(Ash.UUID.generate()),
      gmail: scope!(Ash.UUID.generate())
    })
  end

  defp system(ctx), do: [tenant: ctx.tenant, authorize?: false]

  defp owner(ctx) do
    %{
      owner_id: ctx.user.id,
      owner_type: :user,
      owning_user_id: ctx.user.id,
      owning_business_unit_id: ctx.user.owning_business_unit_id
    }
  end

  defp conversation!(ctx, system, scope, people) do
    Conversation.upsert_from_source!(
      Map.merge(owner(ctx), %{
        external_system: system,
        external_id: "conv-#{System.unique_integer([:positive])}",
        subject: "Synthetic thread",
        participants: %{"emails" => [], "person_ids" => Enum.map(people, & &1.id)},
        erasure_scope_id: scope.id
      }),
      system(ctx)
    )
  end

  defp message!(ctx, conversation, sender) do
    Message.upsert_from_source!(
      Map.merge(owner(ctx), %{
        external_system: conversation.external_system,
        external_id: "msg-#{System.unique_integer([:positive])}",
        body: "Synthetic body",
        sent_at: ~U[2026-10-13 15:00:00.000000Z],
        direction: :inbound,
        conversation_id: conversation.id,
        sender_id: sender.id,
        erasure_scope_id: conversation.erasure_scope_id
      }),
      system(ctx)
    )
  end

  defp event!(ctx, scope, attendees, opts \\ []) do
    CalendarEvent.upsert_from_source!(
      Map.merge(owner(ctx), %{
        external_system: "google_calendar",
        external_id: "evt-#{System.unique_integer([:positive])}",
        title: "Synthetic sync",
        starts_at: ~U[2026-10-13 15:00:00.000000Z],
        ends_at: ~U[2026-10-13 15:30:00.000000Z],
        organizer_id: opts[:organizer] && opts[:organizer].id,
        erasure_scope_id: scope.id,
        attendees: Enum.map(attendees, &%{person_id: &1.id, response_status: "accepted"})
      }),
      system(ctx)
    )
  end

  # One human, two rows: Jane's work address in Slack and Calendar, her home
  # address in Gmail and on one invite alongside her work address. Sam is
  # who both addresses work with.
  defp jane!(ctx) do
    sam = person!(ctx, "sam.rivera@acme.test", "Sam Rivera")
    work = person!(ctx, "jane@acme.test", "Jane Doe")
    home = person!(ctx, "jane.doe@home.test", "Jane Doe")

    slack = conversation!(ctx, "slack", ctx.slack, [work, sam])
    message!(ctx, slack, work)
    standup = event!(ctx, ctx.calendar, [work, sam], organizer: work)

    gmail = conversation!(ctx, "gmail", ctx.gmail, [home, sam])
    home_message = message!(ctx, gmail, home)
    offsite = event!(ctx, ctx.calendar, [home, work])

    %{
      sam: sam,
      work: work,
      home: home,
      gmail: gmail,
      home_message: home_message,
      standup: standup,
      offsite: offsite
    }
  end

  defp publish_steward_review! do
    alias AshEnterprise.Bpmn.Definition

    platform = Seeder.seed_platform_organization().id
    opts = [actor: AshEnterprise.Platform.SystemActor.process(), tenant: platform]

    %{
      key: "mdm.steward_review",
      name: "MDM steward review",
      xml: File.read!("priv/bpmn/mdm_steward_review.bpmn")
    }
    |> Definition.create!(opts)
    |> Definition.publish!(opts)
  end

  defp steward_task!(ctx, candidate) do
    instance =
      AshEnterprise.Bpmn.Instance
      |> Ash.Query.filter(subject_id == ^candidate.id)
      |> Ash.read_one!(system(ctx))

    AshEnterprise.Bpmn.HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id)
    |> Ash.read_one!(system(ctx))
  end

  defp identities(ctx, golden_id) do
    SourceIdentity
    |> Ash.Query.filter(golden_id == ^golden_id)
    |> Ash.read!(system(ctx))
  end

  defp external_ids(ctx, golden_id) do
    ctx |> identities(golden_id) |> MapSet.new(& &1.external_id)
  end

  defp queue(ctx) do
    MatchCandidate
    |> Ash.Query.for_read(:review_queue, %{}, actor: ctx.actor, tenant: ctx.tenant)
    |> Ash.read!(actor: ctx.actor, tenant: ctx.tenant)
  end

  defp reload(ctx, record), do: Ash.reload!(record, system(ctx))

  # A connection of its own, outside the test's sandbox: a session advisory
  # lock belongs to the session that took it, and the sandbox's would be the
  # sweep's own (re-entrant).
  defp lock_session_opts do
    AshEnterprise.Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
  end

  defp participant_ids(ctx, conversation) do
    ConversationParticipant
    |> Ash.Query.filter(conversation_id == ^conversation.id)
    |> Ash.read!(system(ctx))
    |> Enum.map(& &1.person_id)
    |> Enum.sort()
  end

  defp attendees(ctx, event) do
    EventAttendee
    |> Ash.Query.filter(event_id == ^event.id)
    |> Ash.read!(system(ctx))
    |> Map.new(&{&1.person_id, &1.response_status})
  end

  test "two sources, one human: admitted sightings, a review pair, confirm merges, joins follow, unmerge restores",
       ctx do
    jane = jane!(ctx)

    assert {:ok, counts} = Pipeline.run(ctx.tenant)
    # Sam (Slack, Calendar, Gmail), Jane at work (Slack, Calendar), Jane at
    # home (Gmail, Calendar).
    assert counts.observed == 7
    assert counts.staged == 7

    # Exact address → admit: both sightings of the work address are
    # identities of one golden, and nobody was asked.
    assert [_, _] = identities(ctx, jane.work.id)
    assert [_, _] = identities(ctx, jane.home.id)
    assert [_, _, _] = identities(ctx, jane.sam.id)
    work_sightings = external_ids(ctx, jane.work.id)
    home_sightings = external_ids(ctx, jane.home.id)

    goldens = Person |> Ash.Query.for_read(:goldens) |> Ash.read!(system(ctx))
    assert length(goldens) == 3

    # The home address is a review pair against the (older) work address:
    # same name, other domain, shared context. Asked once, though Jane at home
    # was seen by two sources.
    assert [candidate] = queue(ctx)
    assert candidate.golden_id == jane.work.id
    assert candidate.band == :review
    assert Decimal.compare(candidate.score, Decimal.new("0.5")) != :lt
    assert Decimal.compare(candidate.score, Decimal.new("0.9")) == :lt

    staged = Ash.get!(StagedRecord, candidate.staged_record_id, system(ctx))
    assert staged.mapped["person_id"] == jane.home.id
    assert staged.status == :review

    # The morning brief's line: counts only.
    assert {:ok, 1} = People.review_count(actor: ctx.actor, tenant: ctx.tenant)
    {:ok, pulse} = Today.pulse(actor: ctx.actor, tenant: ctx.tenant)

    assert %{value: "1 pair may be the same person — review"} =
             Enum.find(pulse, &(&1.signal == "People"))

    # Idempotent: a second sweep over unchanged people asks nothing new.
    assert {:ok, %{staged: 0, landed: 0}} = Pipeline.run(ctx.tenant)
    assert [_] = queue(ctx)

    # The steward confirms, as a person.
    candidate
    |> Ash.Changeset.for_update(:confirm, %{}, tenant: ctx.tenant, actor: ctx.actor)
    |> Ash.update!(tenant: ctx.tenant, actor: ctx.actor)

    home = reload(ctx, jane.home)
    assert home.merged
    assert home.master_id == jane.work.id
    # The absorbed row keeps its address, so the next projection finds it.
    assert to_string(home.email) == "jane.doe@home.test"

    # One golden with every identity.
    assert external_ids(ctx, jane.work.id) == MapSet.union(work_sightings, home_sightings)
    assert [] = identities(ctx, jane.home.id)

    # Joins follow: the Gmail thread, her message, the offsite invite (where
    # the work address was already invited, the home row was folded in).
    assert participant_ids(ctx, jane.gmail) == Enum.sort([jane.sam.id, jane.work.id])
    assert reload(ctx, jane.home_message).sender_id == jane.work.id
    assert attendees(ctx, jane.offsite) == %{jane.work.id => :accepted}

    work =
      Person
      |> Ash.Query.filter(id == ^jane.work.id)
      |> Ash.Query.load([:conversations, :sent_messages])
      |> Ash.read_one!(system(ctx))

    assert length(work.conversations) == 2
    assert length(work.sent_messages) == 2

    assert queue(ctx) == []
    assert {:ok, 0} = People.review_count(actor: ctx.actor, tenant: ctx.tenant)

    # A later sweep does not re-propose the decided pair.
    assert {:ok, _} = Pipeline.run(ctx.tenant)
    assert queue(ctx) == []

    # Unmerge: Jane at home stands alone again, with what was hers.
    home
    |> Ash.Changeset.for_update(:mdm_unmerge, %{}, system(ctx))
    |> Ash.update!(system(ctx))

    home = reload(ctx, jane.home)
    refute home.merged
    assert home.master_id == nil
    assert external_ids(ctx, jane.home.id) == home_sightings
    # (The sweep in between saw the golden in the Gmail thread its merge
    # moved there, and recorded that sighting too.)
    assert MapSet.subset?(work_sightings, external_ids(ctx, jane.work.id))
    assert participant_ids(ctx, jane.gmail) == Enum.sort([jane.sam.id, jane.home.id])
    assert reload(ctx, jane.home_message).sender_id == jane.home.id

    assert attendees(ctx, jane.offsite) == %{
             jane.home.id => :accepted,
             jane.work.id => :accepted
           }

    # And the unmerge is not undone by the next sweep: the steward's
    # confirmation is the pair's standing answer.
    assert {:ok, _} = Pipeline.run(ctx.tenant)
    assert queue(ctx) == []
    refute reload(ctx, jane.home).merged
  end

  test "namesakes with nothing in common are not merged; same name and domain is a question",
       ctx do
    north = person!(ctx, "alex@north.test", "Alex Kim")
    south = person!(ctx, "alex@south.test", "Alex Kim")
    priya = person!(ctx, "priya@acme.test", "Priya Shah")
    priya_alias = person!(ctx, "p.shah@acme.test", "Priya Shah")

    conversation!(ctx, "gmail", ctx.gmail, [north, person!(ctx, "a@one.test", "One")])
    conversation!(ctx, "slack", ctx.slack, [south, person!(ctx, "b@two.test", "Two")])
    conversation!(ctx, "gmail", ctx.gmail, [priya])
    conversation!(ctx, "slack", ctx.slack, [priya_alias])

    assert {:ok, _} = Pipeline.run(ctx.tenant)

    # Same name alone: scored, banded omit, and spent — never queued.
    alex_pairs =
      MatchCandidate
      |> Ash.Query.filter(golden_id == ^north.id)
      |> Ash.read!(system(ctx))
      |> Enum.reject(&(&1.band == :admit))

    assert [%{band: :omit, status: :superseded}] = alex_pairs
    refute reload(ctx, south).merged
    refute reload(ctx, north).merged

    # Same name and same domain, other address: a steward's question.
    assert [candidate] = queue(ctx)
    assert candidate.golden_id == priya.id
    staged = Ash.get!(StagedRecord, candidate.staged_record_id, system(ctx))
    assert staged.mapped["person_id"] == priya_alias.id

    # A rejected pair stays apart, and is not asked again.
    candidate
    |> Ash.Changeset.for_update(:reject, %{}, tenant: ctx.tenant, actor: ctx.actor)
    |> Ash.update!(tenant: ctx.tenant, actor: ctx.actor)

    refute reload(ctx, priya_alias).merged
    assert [_] = identities(ctx, priya_alias.id)
    assert {:ok, _} = Pipeline.run(ctx.tenant)
    assert queue(ctx) == []
  end

  test "the steward-decision task decides a people pair exactly as the queue does", ctx do
    publish_steward_review!()
    jane = jane!(ctx)

    assert {:ok, %{review: 1}} = Pipeline.run(ctx.tenant)
    assert [candidate] = queue(ctx)

    # The review-banded pair opened the steward-review process; its task is
    # the other entry point to the same verdict.
    task = steward_task!(ctx, candidate)
    assert task.status in [:open, :claimed]

    assert {:ok, _message} =
             AshEnterprise.Mdm.StewardTask.decide(task, candidate.id, "confirm", nil,
               actor: ctx.actor,
               tenant: ctx.tenant
             )

    assert reload(ctx, candidate).status == :confirmed
    assert reload(ctx, task).status == :completed

    # The same act as the queue's confirm: the person merged, joins followed.
    home = reload(ctx, jane.home)
    assert home.merged
    assert home.master_id == jane.work.id
    assert reload(ctx, jane.home_message).sender_id == jane.work.id
    assert participant_ids(ctx, jane.gmail) == Enum.sort([jane.sam.id, jane.work.id])
    assert queue(ctx) == []
  end

  test "replay: delete the goldens, replay, the same rows come back", ctx do
    sam = person!(ctx, "sam.rivera@acme.test", "Sam Rivera")
    work = person!(ctx, "jane@acme.test", "Jane Doe")
    home = person!(ctx, "jane.doe@home.test", "Jane Doe")
    conversation!(ctx, "slack", ctx.slack, [work, sam])
    event!(ctx, ctx.calendar, [work, sam])
    conversation!(ctx, "gmail", ctx.gmail, [home, sam])

    assert {:ok, _} = Pipeline.run(ctx.tenant)
    assert [candidate] = queue(ctx)

    candidate
    |> Ash.Changeset.for_update(:confirm, %{}, tenant: ctx.tenant, actor: ctx.actor)
    |> Ash.update!(tenant: ctx.tenant, actor: ctx.actor)

    goldens = fn ->
      Person
      |> Ash.Query.for_read(:goldens)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(system(ctx))
      |> Enum.map(&{&1.id, &1.name, to_string(&1.email), &1.merged, &1.master_id})
    end

    before = goldens.()
    # Jane at work survives with her own address, never the absorbed one.
    assert {work.id, "Jane Doe", "jane@acme.test", false, nil} in before
    assert length(before) == 2

    AshEnterprise.Repo.query!("DELETE FROM canonical_people", [])
    assert {:ok, 2} = AshEnterprise.Mdm.Projection.replay(tenant: ctx.tenant)
    assert goldens.() == before

    AshEnterprise.Repo.query!("DELETE FROM canonical_people", [])
    assert {:ok, 2} = AshEnterprise.Mdm.Projection.replay(tenant: ctx.tenant)
    assert goldens.() == before
  end

  test "the sweep runs per tenant that turned it on, and is a no-op on nothing new", ctx do
    person!(ctx, "solo@acme.test", "Solo Person")
    |> then(&conversation!(ctx, "slack", ctx.slack, [&1]))

    assert ctx.tenant in SweepWorker.tenants()
    assert :ok = SweepWorker.perform(%Oban.Job{args: %{"tenant" => ctx.tenant}})
    assert [_] = Person |> Ash.Query.for_read(:goldens) |> Ash.read!(system(ctx))

    assert {:ok, %{staged: 0}} = Pipeline.run(ctx.tenant)

    other = tenant!()
    assert {:ok, :not_configured} = Pipeline.run(other.tenant)
  end

  test "one sweep per tenant at a time: while one holds the tenant, another does nothing",
       ctx do
    person!(ctx, "solo@acme.test", "Solo Person")
    |> then(&conversation!(ctx, "slack", ctx.slack, [&1]))

    # Another session's sweep of this tenant (the mix task while the cron's
    # job runs, or the other way round): its own connection, its own lock.
    other_session = start_supervised!({Postgrex, lock_session_opts()})
    lock = ["mdm.people_sweep", ctx.tenant]
    Postgrex.query!(other_session, "SELECT pg_advisory_lock(hashtext($1), hashtext($2))", lock)

    assert {:ok, :busy} = Pipeline.run(ctx.tenant)
    assert :ok = SweepWorker.perform(%Oban.Job{args: %{"tenant" => ctx.tenant}})
    assert Ash.read!(StagedRecord, system(ctx)) == []

    # Another tenant is not held.
    other = tenant!()
    assert {:ok, :not_configured} = Pipeline.run(other.tenant)

    Postgrex.query!(other_session, "SELECT pg_advisory_unlock(hashtext($1), hashtext($2))", lock)
    assert {:ok, %{staged: 1}} = Pipeline.run(ctx.tenant)
    assert {:ok, %{staged: 0}} = Pipeline.run(ctx.tenant)
  end

  test "a sweep killed mid-route: the next one asks the abandoned pair again, once", ctx do
    priya = person!(ctx, "priya@acme.test", "Priya Shah")
    priya_alias = person!(ctx, "p.shah@acme.test", "Priya Shah")
    conversation!(ctx, "gmail", ctx.gmail, [priya])
    conversation!(ctx, "slack", ctx.slack, [priya_alias])

    assert {:ok, _} = Pipeline.run(ctx.tenant)
    assert [asked] = queue(ctx)

    # Rewind the alias's row to where a kill between scoring and routing
    # leaves it: still staged, its candidates written but never banded.
    staged = Ash.get!(StagedRecord, asked.staged_record_id, system(ctx))
    Ash.update!(staged, %{status: :staged}, Keyword.put(system(ctx), :action, :update))

    MatchCandidate
    |> Ash.Query.filter(staged_record_id == ^staged.id)
    |> Ash.read!(system(ctx))
    |> Enum.each(
      &Ash.update!(&1, %{band: nil, status: :pending}, Keyword.put(system(ctx), :action, :update))
    )

    assert queue(ctx) == []

    assert {:ok, %{staged: 1, review: 1}} = Pipeline.run(ctx.tenant)

    assert [again] = queue(ctx)
    assert again.golden_id == priya.id
    assert again.id != asked.id

    assert Ash.get!(StagedRecord, again.staged_record_id, system(ctx)).mapped["person_id"] ==
             priya_alias.id

    # The abandoned row's candidates are spent, not left standing.
    assert MatchCandidate
           |> Ash.Query.filter(staged_record_id == ^staged.id and status != :superseded)
           |> Ash.read!(system(ctx)) == []

    assert {:ok, %{staged: 0}} = Pipeline.run(ctx.tenant)
    assert [%{id: id}] = queue(ctx)
    assert id == again.id
  end

  test "seeding is idempotent and person-gated", ctx do
    first = People.rule_set(ctx.tenant)
    mapping = People.mapping(ctx.tenant)

    assert %{rule_set: %{id: rule_set_id}, mapping: %{id: mapping_id}} =
             Seed.seed!(ctx.tenant, ctx.actor)

    assert rule_set_id == first.id
    assert mapping_id == mapping.id

    # The CSV import's rule set is a different key: activating the people
    # rule set retires nothing of the import's.
    assert first.golden_resource == "AshEnterprise.Canonical.Person#people"

    other = tenant!()

    assert_raise Ash.Error.Forbidden, fn ->
      Seed.seed!(other.tenant, AshEnterprise.Platform.SystemActor.system())
    end
  end
end
