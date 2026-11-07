defmodule Battery.Integration.OperationsDisclosureDecisionTest do
  @moduledoc """
  Operations — disclosure gate ↔ published decision.

  The seam: ash_operations' `DisclosureGate` (asked inside the generated action, before a
  byte is sent) meets ash_decisions' published-and-recorded evaluation
  (`Battery.Operations.Gate` evaluates the latest PUBLISHED `battery_disclosure_permitted`
  through `AshDecisions.Evaluator`), and ash_agent's `denied` failure class.

  Asserted: a refusal sends nothing, and names the policy version that gave it; the
  evaluation is recorded with the definition's key, version, content hash and matched rule
  ids, over the three inputs the gate chose and none of the payload; a permit sends once;
  publishing version 2 of the decision flips the same call to a refusal with no code change;
  through an invocation a refusal is a `denied` failure, final and not retried; and the
  residency the gate decides on is the transport's own declaration, not anything the caller
  passes.
  """

  use ExUnit.Case, async: false

  alias Battery.Decisions.{Definition, Evaluation}
  alias Battery.Execution.{Invocation, Member}
  alias Battery.Operations.{Registry, Submission}
  alias Battery.OperationsStub

  @key "battery_disclosure_permitted"
  @submit "Battery.Operations.Submission.submit"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_invocations battery_submissions battery_members battery_event_log) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    Enum.each([Evaluation, Definition], &Battery.Repo.delete_all/1)
    Battery.Lineage.Capture.clear()

    Application.put_env(:ash_enterprise_battery, :operations_residency, :sub_processor)
    on_exit(fn -> Application.delete_env(:ash_enterprise_battery, :operations_residency) end)

    count =
      OperationsStub.install!(fn %{method: "POST"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"clientReference" => ref} = Jason.decode!(body)

        OperationsStub.json(conn, 201, %{
          "id" => "act-1",
          "clientReference" => ref,
          "status" => "active"
        })
      end)

    publish_policy!(1)

    %{
      count: count,
      member: Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"}),
      personal: submission!("personal", false)
    }
  end

  defp submission!(data_class, consent) do
    Ash.create!(Submission, %{data_class: data_class, consent_on_file: consent})
  end

  defp publish_policy!(version) do
    definition =
      Definition.create!(%{
        key: @key,
        name: "Battery disclosure permitted",
        xml: Battery.Fixtures.disclosure_permitted_dmn(version)
      })

    assert definition.graph, "policy v#{version} failed to compile: #{inspect(definition.errors)}"
    {:ok, published} = Definition.publish(definition)
    published
  end

  defp create(submission, member, reference \\ "SYNTHETIC-ref") do
    Registry.create_activation(
      %{client_reference: reference, disclosure_ref: submission.id},
      actor: member
    )
  end

  defp refusal({:error, error}), do: AshOperations.Error.unwrap(error)

  defp evaluations, do: Evaluation |> Ash.Query.sort(inserted_at: :asc) |> Ash.read!()

  test "a refusal sends nothing, and the evaluation records what the gate asked and what fired",
       ctx do
    assert %{reason: :disclosure_refused, provider_code: "consent_required@v1"} =
             refusal(create(ctx.personal, ctx.member))

    assert ctx.count.("POST", "/activations") == 0

    assert [evaluation] = evaluations()
    published = Definition.by_key_version!(@key, 1)

    assert {evaluation.definition_key, evaluation.definition_version} == {@key, 1}
    assert hd(evaluation.matched_rule_ids) == "rule_consent_required"
    assert evaluation.outputs["value"] == "consent_required"

    # The row names the exact definition, and so its content hash: immutable once published.
    assert evaluation.definition_id == published.id
    assert is_binary(published.content_hash) and published.content_hash != ""

    # Exactly the three inputs the gate chose; nothing from the call's payload.
    assert evaluation.inputs == %{
             "data_class" => "personal",
             "destination_residency" => "sub_processor",
             "consent_on_file" => false
           }

    refute inspect(evaluation.inputs) =~ "SYNTHETIC-ref"
  end

  test "with consent on file the call is permitted, and the permit is recorded too", ctx do
    consented = submission!("personal", true)

    assert {:ok, %{"id" => "act-1"}} = create(consented, ctx.member)
    assert ctx.count.("POST", "/activations") == 1

    assert [evaluation] = evaluations()
    assert hd(evaluation.matched_rule_ids) == "rule_permit"
    assert evaluation.outputs["value"] == "permitted"
  end

  test "publishing version 2 of the decision flips the same call, with no code change", ctx do
    consented = submission!("personal", true)
    assert {:ok, _} = create(consented, ctx.member)
    assert ctx.count.("POST", "/activations") == 1

    publish_policy!(2)

    assert %{reason: :disclosure_refused, provider_code: "residency@v2"} =
             refusal(create(consented, ctx.member))

    assert ctx.count.("POST", "/activations") == 1

    assert [_v1, latest] = evaluations()
    assert {latest.definition_version, hd(latest.matched_rule_ids)} == {2, "rule_residency"}
  end

  test "through an invocation a refusal is denied: final, not outcome_unknown, never retried",
       ctx do
    row = invoke!(ctx.member, ctx.personal)
    assert row.status == :ready

    assert execute(row) == :failed
    failed = Ash.get!(Invocation, row.id)

    assert {failed.status, failed.failure_class, failed.error_code} ==
             {:failed, :denied, "consent_required@v1"}

    assert AshAgent.FailureClass.classify(
             AshOperations.Error.exception(
               reason: :disclosure_refused,
               provider_code: "consent_required@v1"
             )
           ) == {:denied, "consent_required@v1"}

    # Nothing was sent, and a second execute of the settled row runs nothing.
    assert execute(row) == :skipped
    assert ctx.count.("POST", "/activations") == 0
    assert length(evaluations()) == 1
  end

  test "the residency the gate decides on is the transport's declaration, not the caller's",
       ctx do
    Application.put_env(:ash_enterprise_battery, :operations_residency, :in_cluster)

    # The same unconsented personal data: in cluster, the table permits it.
    assert {:ok, %{"id" => "act-1"}} = create(ctx.personal, ctx.member)
    assert ctx.count.("POST", "/activations") == 1

    assert [evaluation] = evaluations()
    assert evaluation.inputs["destination_residency"] == "in_cluster"
    assert hd(evaluation.matched_rule_ids) == "rule_permit"
  end

  defp invoke!(member, submission) do
    Invocation
    |> Ash.ActionInput.for_action(
      :invoke,
      %{target: @submit, args: %{"id" => submission.id}, key: "submit:#{submission.id}"},
      actor: member
    )
    |> Ash.run_action!()
  end

  defp execute(row) do
    Invocation
    |> Ash.ActionInput.for_action(:execute, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end
end
