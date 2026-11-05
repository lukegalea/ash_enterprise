defmodule Battery.Integration.ReleaseManifestTest do
  @moduledoc """
  Scenario 9 — release manifest ↔ approval, and a pinned decision for an older case.

  Two halves of what a release pins.

  **The digest carried into an approval.** A governed invocation of a four-eyes target
  waits on a standalone ash_bpmn `HumanTask`. When a release covers the target
  (`AshAgent.ReleaseManifest`), the request records it as `release_manifest_id` and the
  approval binds its digest as `manifest_digest` in the RFC 9396 `authorization_details`,
  so it is part of the JCS `approval_digest` the task's approver approved. A decision
  applied while the same release is active makes the row ready. A different release made
  active while the approval waits leaves the row `stale` (`manifest_changed`), and nothing
  runs.

  **A decision version pinned for an older case.** A BPMN business rule task's decision is
  resolved by a host resolver that reads the subject the engine hands it. A subject pinned
  to decision version 1 is answered by version 1 after version 2 is published; one nothing
  pins is answered by version 2.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Battery.Bpmn.{Definition, PinnedDecisionResolver, ProcessEvent, Subject}
  alias Battery.Decisions
  alias Battery.Execution.{Invocation, Member, Referral, ReleaseManifest, RequestApproval}
  alias Battery.Bpmn.HumanTask

  @escalate "Battery.Execution.Referral.escalate"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_invocations battery_referrals battery_members bpmn_task_candidates
                    bpmn_human_tasks bpmn_process_events bpmn_definitions bpmn_instances
                    bpmn_tokens bpmn_test_subjects) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    Battery.Repo.delete_all(Decisions.Definition)
    Battery.Repo.delete_all(Decisions.Evaluation)

    previous = Application.get_env(:ash_bpmn, :decision_resolver)

    on_exit(fn ->
      ReleaseManifest.clear()
      PinnedDecisionResolver.clear()

      if previous,
        do: Application.put_env(:ash_bpmn, :decision_resolver, previous),
        else: Application.delete_env(:ash_bpmn, :decision_resolver)
    end)

    :ok
  end

  defp unique, do: System.unique_integer([:positive])
  defp release(n), do: AshAgent.Digest.sha256_hex(%{"release" => n})

  describe "the digest carried into an approval" do
    setup do
      requester = Ash.create!(Member, %{name: "Dana (nurse)", role: "clinic_lead"})
      lead = Ash.create!(Member, %{name: "Sam (clinic lead)", role: "clinic_lead"})
      referral = Ash.create!(Referral, %{patient: "SYNTHETIC patient #{unique()}"})
      %{requester: requester, lead: lead, referral: referral}
    end

    defp request!(ctx) do
      Ash.ActionInput.for_action(
        Invocation,
        :invoke,
        %{target: @escalate, args: %{"id" => ctx.referral.id}, key: "escalate:#{unique()}"},
        actor: ctx.requester
      )
      |> Ash.run_action!()
    end

    defp approve!(row, lead) do
      key = RequestApproval.key()
      id = row.id

      task =
        HumanTask
        |> Ash.Query.filter(subject_id == ^id and node_id == ^key)
        |> Ash.read_one!(authorize?: false)

      {:ok, _} = AshBpmn.complete_task(task, outcome: :approved, actor: lead)

      Ash.get!(Invocation, row.id)
      |> Ash.Changeset.for_update(:apply_decision, %{})
      |> Ash.update!()
    end

    test "the active release's digest is bound by the approval and recorded on the row", ctx do
      active = ReleaseManifest.activate(release(1))
      row = request!(ctx)

      assert [%{"manifest_digest" => digest}] = row.authorization_details
      assert {digest, row.release_manifest_id} == {active.digest, active.id}
      assert row.approval_digest == AshAgent.Digest.sha256_hex(row.authorization_details)

      assert approve!(row, ctx.lead).status == :ready
    end

    test "a different release active while the approval waits leaves it stale", ctx do
      ReleaseManifest.activate(release(1))
      row = request!(ctx)
      ReleaseManifest.activate(release(2))

      stale = approve!(row, ctx.lead)
      assert {stale.status, stale.error_code} == {:stale, "manifest_changed"}
      refute Ash.get!(Referral, ctx.referral.id).urgent?
    end

    test "with no release, nothing is bound", ctx do
      row = request!(ctx)
      assert [%{"manifest_digest" => nil}] = row.authorization_details
      assert row.release_manifest_id == nil
      assert approve!(row, ctx.lead).status == :ready
    end
  end

  describe "a pinned decision version for an older case" do
    test "the pinned subject is answered by version 1 after version 2 is published" do
      Application.put_env(:ash_bpmn, :decision_resolver, PinnedDecisionResolver)

      one = publish_decision!(Battery.Fixtures.amount_tier_dmn())
      assert one.version == 1
      publish_process!()

      old = Ash.create!(Subject, %{name: "battery_old_case", amount: 500})
      new = Ash.create!(Subject, %{name: "battery_new_case", amount: 500})
      PinnedDecisionResolver.pin(old.id, one.id)

      # Version 2 lowers the threshold: 500 is now high.
      two =
        Battery.Fixtures.amount_tier_dmn()
        |> String.replace("&gt;= 1000", "&gt;= 100")
        |> String.replace("&lt; 1000", "&lt; 100")
        |> publish_decision!()

      assert two.version == 2

      assert tier(old) == {"low", "1"}
      assert tier(new) == {"high", "2"}
    end
  end

  defp publish_decision!(xml) do
    definition =
      Decisions.Definition.create!(%{key: "battery_amount_tier", name: "Tier", xml: xml})

    {:ok, published} = Decisions.Definition.publish(definition)
    published
  end

  defp publish_process! do
    defn =
      Definition.create!(%{
        key: "battery_risk",
        name: "Battery risk",
        xml: Battery.Fixtures.amount_tier_process()
      })

    Battery.Repo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = '#{defn.id}'"
    )
  end

  # The case's tier and the decision version that answered, as the engine recorded them.
  defp tier(subject) do
    {:ok, instance} =
      AshBpmn.start_instance(Battery.Domain, process: "battery_risk", subject: subject)

    [event] =
      ProcessEvent
      |> Ash.Query.filter(instance_id == ^instance.id and kind == :decision_evaluated)
      |> Ash.read!()

    {event.data["promoted"]["tier"], event.data["decision_version"]}
  end
end
