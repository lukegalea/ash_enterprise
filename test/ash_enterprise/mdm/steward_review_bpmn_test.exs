defmodule AshEnterprise.Mdm.StewardReviewBpmnTest do
  @moduledoc """
  The process side of stewardship (MDM-4): a review-banded candidate starts
  an `mdm.steward_review` instance; its user task is the claimable work item;
  the steward's confirm — wherever made — completes that task, and the
  instance finishes with the outcome.

  The decision is deliberately NOT a service task: confirm/reject are the
  candidate's person-gated actions, and the engine actor must never be able
  to drive a merge (that gate is MDM-4's point).
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Mdm.{ImportBatch, MatchCandidate}
  alias AshEnterprise.Platform.Seeder

  require Ash.Query

  @xml File.read!("priv/bpmn/mdm_steward_review.bpmn")

  setup do
    Seeder.seed_platform_organization()
    AshEnterprise.Mdm.Banding.publish_seed_bands!(platform_org())

    definition =
      Definition.create!(%{key: "mdm.steward_review", name: "MDM steward review", xml: @xml},
        actor: AshEnterprise.Platform.SystemActor.process(),
        tenant: platform_org()
      )

    Definition.publish!(definition,
      actor: AshEnterprise.Platform.SystemActor.process(),
      tenant: platform_org()
    )

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        name: "Bpmn Steward #{System.unique_integer([:positive])}",
        unique_name: "bpmn-steward-#{System.unique_integer([:positive])}"
      )

    %{org: organization.id, admin: admin}
  end

  defp platform_org, do: Seeder.seed_platform_organization().id

  defp seed_rule_set!(org, admin) do
    rules = [
      %{"name" => "email_exact", "kind" => "exact", "fields" => ["email"], "weight" => 1.0},
      %{
        "name" => "name_fuzzy",
        "kind" => "fuzzy",
        "field" => "name",
        "algorithm" => "levenshtein",
        "weight" => 0.5
      }
    ]

    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Changeset.for_create(:draft, %{
      golden_resource: "AshEnterprise.Canonical.Person",
      rules: rules
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> then(fn rule_set ->
      rule_set
      |> Ash.Changeset.for_update(:activate, %{}, tenant: org, actor: admin)
      |> Ash.update!(tenant: org, actor: admin)
    end)
  end

  defp golden_person!(org, admin, name, email) do
    AshEnterprise.Canonical.Person
    |> Ash.Changeset.for_create(:upsert_from_source, %{
      name: name,
      email: email,
      owner_id: admin.id,
      owning_business_unit_id: admin.owning_business_unit_id
    })
    |> Ash.create!(tenant: org, authorize?: false)
  end

  defp review_candidate!(org, admin) do
    golden_person!(org, admin, "Ann Existing", "ann@x.io")

    {:ok, _record} =
      AshEnterprise.Mdm.Landing.land_row(org, "acme", %{
        "Email" => "ann@x.io",
        "Full Name" => "Ann Existing-Smith"
      })

    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    batch =
      ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "acme"},
        tenant: org,
        authorize?: false
      )
      |> Ash.create!(tenant: org, authorize?: false)

    {:ok, _job} =
      %{"batch_id" => batch.id, "tenant" => batch.organization_id}
      |> AshEnterprise.Mdm.BatchWorker.new()
      |> Oban.insert()

    Oban.drain_queue(queue: :mdm, with_safety: false)
    # Token advancement and task creation run as Oban jobs on :bpmn.
    Oban.drain_queue(queue: :bpmn, with_safety: false)

    MatchCandidate
    |> Ash.Query.filter(band == ^:review and status == ^:pending)
    |> Ash.read_one!(tenant: org, authorize?: false)
  end

  test "a review-banded candidate opens a steward task; confirming completes it", %{
    org: org,
    admin: admin
  } do
    seed_rule_set!(org, admin)
    candidate = review_candidate!(org, admin)

    require Logger

    instance =
      AshEnterprise.Bpmn.Instance
      |> Ash.Query.filter(subject_id == ^candidate.id)
      |> Ash.read_one!(tenant: org, authorize?: false)

    task =
      AshEnterprise.Bpmn.HumanTask
      |> Ash.Query.filter(instance_id == ^instance.id and status == ^:open)
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert task != nil, "the review-banded candidate has an open steward task"

    # The steward decides — the same person-gated act the queue drives.
    candidate =
      candidate
      |> Ash.Changeset.for_update(:confirm, %{}, tenant: org, actor: admin)
      |> Ash.update!(tenant: org, actor: admin)
      |> Ash.reload!(tenant: org, authorize?: false)

    assert %{status: :completed} =
             Ash.reload!(task, tenant: org, authorize?: false)

    assert %{status: :completed} =
             AshEnterprise.Bpmn.Instance
             |> Ash.Query.filter(id == ^task.instance_id)
             |> Ash.read_one!(tenant: org, authorize?: false)

    # The decision's System One ledger rows exist (the wiring under the act).
    verdict =
      AshEnterprise.SystemOne.HumanVerdict
      |> Ash.Query.filter(id == ^candidate.human_verdict_ref["verdict_id"])
      |> Ash.read_one!(tenant: org, authorize?: false)

    assert to_string(verdict.human_value) == "match"
    assert verdict.basis == :review_task
  end
end
