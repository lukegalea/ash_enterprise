defmodule AshEnterprise.Mdm.QualityStewardshipTest do
  @moduledoc """
  The findings→stewardship slice (MDM-7): a noncompliant quality finding
  starts an `mdm.quality_review` instance explicitly (Resolver + pinned
  definition — no subscription, no in-tenant resolution gap), its user task
  is claimable stewardship work, and completing it finishes the instance.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  @xml File.read!("priv/bpmn/mdm_quality_review.bpmn")

  setup do
    Seeder.seed_platform_organization()
    AshEnterprise.Mdm.QualityReview.seed_quality_catalog(platform_org())

    definition =
      Definition.create!(%{key: "mdm.quality_review", name: "MDM quality review", xml: @xml},
        actor: AshEnterprise.Platform.SystemActor.process(),
        tenant: platform_org()
      )

    Definition.publish!(definition,
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: platform_org()
    )

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Qual Steward #{System.unique_integer([:positive])}",
        unique_name: "qual-steward-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  defp platform_org, do: Seeder.seed_platform_organization().id

  test "a noncompliant golden opens a claimable quality task; resolving finishes it", %{
    org: org,
    admin: admin
  } do
    golden =
      Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: "No Mail Nick",
        email: nil,
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    # The review emits events (an append on the governed log: the seeded
    # admin is the acting officer); the projector files a noncompliant
    # contact finding; the explicit start makes it claimable work.
    officer =
      AshEnterprise.Security.ActorContext.attach(
        admin,
        AshEnterprise.Security.ActorContext.build(admin, tenant: org)
      )

    :ok = AshEnterprise.Mdm.QualityReview.review_golden(org, golden, actor: officer)

    events =
      AshEnterprise.Compliance.EventLog
      |> Ash.Query.filter(action == ^:mdm_reviewed)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(authorize?: false)

    :ok =
      AshCompliance.Testing.drain_sync(
        AshEnterprise.Mdm.QualityProjector,
        Enum.map(events, fn event ->
          %{
            id: event.id,
            practice_id: event.practice_id,
            user_id: event.user_id,
            occurred_at: event.occurred_at,
            metadata: event.metadata,
            resource: event.resource,
            action: event.action,
            action_type: event.action_type
          }
        end)
      )

    :ok =
      AshEnterprise.Mdm.QualityReview.start_stewardship!(org, "mdm.contact", to_string(golden.id))

    task =
      AshEnterprise.Bpmn.HumanTask
      |> Ash.Query.filter(status == ^:open)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert task != nil, "the noncompliant finding is claimable stewardship work"

    AshBpmn.complete_task!(task, outcome: "resolved", actor: admin)

    assert %{status: :completed} = Ash.reload!(task, tenant: org, authorize?: false)
  end
end
