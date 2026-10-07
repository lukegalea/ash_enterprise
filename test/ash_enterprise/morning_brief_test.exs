defmodule AshEnterprise.MorningBriefTest do
  @moduledoc """
  Epic E5 acceptance, morning-brief slice: the BPMN process runs a
  deterministic compose (no LLM), parks on a real human-approval row, and the
  decision lands on the brief.

  * seeding calendar SourceObjects → `Projection.replay(:calendar)` gives the
    day's canonical events,
  * `start_instance` runs the process to the approval task with a draft that
    names a known event,
  * approving completes the instance and marks the brief approved,
  * rejecting marks it rejected,
  * a day with no events composes the explicit fallback, never silence.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance}
  alias AshEnterprise.Canonical.Projection
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Platform.SystemActor

  require Ash.Query

  @opts [authorize?: false]
  @xml File.read!("priv/bpmn/morning_brief.bpmn")

  setup do
    # A real provisioned tenant: the grant model, not `authorize?: false`, is
    # what the process engine exercises (it never drops authorization).
    tenant =
      AshEnterprise.Platform.Seeder.seed_tenant(
        name: "Brief Corp",
        unique_name: "brief-corp",
        email: "admin@brief.test"
      )

    %{org: tenant.organization, user: tenant.user}
  end

  defp publish_definition!(org) do
    definition =
      Definition.create!(%{key: "morning.brief", name: "Morning brief", xml: @xml},
        actor: SystemActor.process(),
        tenant: org.id
      )

    Definition.publish!(definition, actor: SystemActor.process(), tenant: org.id)
  end

  defp seed_event!(external_id, summary, starts_at, ends_at) do
    SourceObject.land!(
      %{
        external_system: "calendar",
        external_id: external_id,
        raw_payload: %{
          "id" => external_id,
          "iCalUID" => "#{external_id}@brief.test",
          "summary" => summary,
          "start" => %{"dateTime" => DateTime.to_iso8601(starts_at)},
          "end" => %{"dateTime" => DateTime.to_iso8601(ends_at)},
          "location" => "War room",
          "organizer" => %{"email" => "operator@brief.test"}
        },
        source_metadata: %{"stream" => "events", "external_system" => "calendar"},
        fetched_at: DateTime.utc_now()
      },
      @opts
    )
  end

  defp start_brief!(org, user, date) do
    brief =
      MorningBrief
      |> Ash.Changeset.for_create(:start_for_date, %{brief_date: date},
        actor: user,
        tenant: org.id
      )
      |> Ash.create!()

    instance =
      AshBpmn.start_instance!(AshEnterprise.Bpmn,
        process: "morning.brief",
        subject: brief,
        actor: user,
        tenant: org.id
      )

    {brief, instance}
  end

  defp open_task!(org, instance_id) do
    HumanTask
    |> Ash.Query.filter(instance_id == ^instance_id and status == :open)
    |> Ash.read_one!(authorize?: false, tenant: org.id)
    |> Kernel.||(flunk("no open approval task for instance #{instance_id}"))
  end

  defp reload_brief!(org, id) do
    MorningBrief
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false, tenant: org.id)
  end

  defp reload_instance!(org, id) do
    Instance
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false, tenant: org.id)
  end

  test "compose → approval → approve completes the instance with the draft stored", %{
    org: org,
    user: user
  } do
    publish_definition!(org)

    today = Date.utc_today()
    noon = DateTime.new!(today, ~T[12:00:00], "Etc/UTC")

    seed_event!(
      "brief_evt_1",
      "Weekly plan review",
      DateTime.add(noon, -3, :hour),
      DateTime.add(noon, -150, :minute)
    )

    seed_event!("brief_evt_2", "Design review with Alice", noon, DateTime.add(noon, 1, :hour))

    assert {:ok, _} = Projection.replay(:calendar, owner: user, tenant: org.id)

    {brief, instance} = start_brief!(org, user, today)

    # The deterministic compose ran on the way to the approval task; the
    # process is parked on a real human-task row, not an ETS entry.
    brief = reload_brief!(org, brief.id)
    assert brief.status == :pending_approval
    assert brief.draft_text =~ "Morning brief for #{Date.to_iso8601(today)}"
    assert brief.draft_text =~ "Design review with Alice"
    assert brief.draft_text =~ "War room"
    # Two events, in start order, with times.
    assert brief.draft_text =~ "09:00–09:30  Weekly plan review"
    assert brief.draft_text =~ "12:00–13:00  Design review with Alice"

    task = open_task!(org, instance.id)
    assert task.status == :open

    AshBpmn.complete_task!(task, outcome: "approved", actor: user)

    assert %{status: :approved} = reload_brief!(org, brief.id)
    assert %{status: :completed} = reload_instance!(org, instance.id)
  end

  test "reject marks the brief rejected and completes the instance", %{org: org, user: user} do
    publish_definition!(org)

    today = Date.utc_today()
    {brief, instance} = start_brief!(org, user, today)

    assert %{draft_text: "Morning brief for " <> _, status: :pending_approval} =
             reload_brief!(org, brief.id)

    task = open_task!(org, instance.id)
    AshBpmn.complete_task!(task, outcome: "rejected", actor: user)

    assert %{status: :rejected} = reload_brief!(org, brief.id)
    assert %{status: :completed} = reload_instance!(org, instance.id)
  end

  test "a day with no events composes the explicit fallback", %{org: org, user: user} do
    publish_definition!(org)

    today = Date.utc_today()
    {brief, instance} = start_brief!(org, user, today)

    assert %{draft_text: draft} = reload_brief!(org, brief.id)
    assert draft =~ "No events scheduled"

    task = open_task!(org, instance.id)
    AshBpmn.complete_task!(task, outcome: "approved", actor: user)

    assert %{status: :approved} = reload_brief!(org, brief.id)
  end
end
