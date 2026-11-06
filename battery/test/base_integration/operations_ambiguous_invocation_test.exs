defmodule Battery.Integration.OperationsAmbiguousInvocationTest do
  @moduledoc """
  Operations — ambiguous provider create ↔ governed invocation reconcile.

  The seam: ash_operations' retry table and its `:ambiguous` failure meet ash_agent's
  executor and reconciler, through the host's `AshAgent.FailureClass`
  (`Battery.Operations.FailureClass`), with the outcome recorded once through AshEvents and
  ash_open_lineage.

  A governed `Submission.submit` calls the provider's non-idempotent `create_activation`,
  keyed by the invocation's own key. The provider takes the call and loses the answer.

  Asserted: the row is `outcome_unknown` with `ambiguous`, after ONE send and no wait (it is
  never re-sent); a redelivery of the execute skips; the reconciler asks the provider by the
  invocation's key, finds the one activation, and settles the row `succeeded` with the
  activation as its effect, with still one send; reconciling again moves nothing; the
  transition is recorded once in the event log and emitted once as lineage, and the lineage
  carries no actor, key or activation id. Negative halves: no match, or two, leave the row
  `outcome_unknown` for a person, never `failed`; and a 429 is `transient` with its
  `Retry-After`, never `outcome_unknown`.
  """

  use ExUnit.Case, async: false

  alias Battery.Decisions.{Definition, Evaluation}
  alias Battery.Events.EventLog
  alias Battery.Execution.{Invocation, Member}
  alias Battery.Lineage.Capture
  alias Battery.Operations.{Registry, Submission}
  alias Battery.OperationsStub

  @submit "Battery.Operations.Submission.submit"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    for table <- ~w(battery_invocations battery_submissions battery_members battery_event_log) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    Enum.each([Evaluation, Definition], &Battery.Repo.delete_all/1)
    Capture.clear()

    # The gate permits ordinary data: this scenario is about what happens after the send.
    definition =
      Definition.create!(%{
        key: "battery_disclosure_permitted",
        name: "Battery disclosure permitted",
        xml: Battery.Fixtures.disclosure_permitted_dmn(1)
      })

    {:ok, _published} = Definition.publish(definition)

    {:ok, provider} = Agent.start_link(fn -> %{accepted: nil, listing: :matching} end)

    %{
      provider: provider,
      member: Ash.create!(Member, %{name: "Dana (nurse)", role: "nurse"}),
      submission: Ash.create!(Submission, %{data_class: "general", consent_on_file: false})
    }
  end

  # The provider takes the activation and then loses the answer; its list shows what
  # `listing` says: the one it took, nothing, or two.
  defp lossy_provider!(provider, post \\ &Req.Test.transport_error(&1, :timeout)) do
    OperationsStub.install!(fn
      %{method: "POST"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"clientReference" => ref} = Jason.decode!(body)
        Agent.update(provider, &%{&1 | accepted: ref})
        post.(conn)

      %{method: "GET", request_path: "/activations"} = conn ->
        %{accepted: ref, listing: listing} = Agent.get(provider, & &1)
        mine = %{"id" => "act-7", "clientReference" => ref, "status" => "active"}
        twin = %{mine | "id" => "act-8"}
        stranger = %{mine | "id" => "act-9", "clientReference" => "someone-else"}

        data =
          case listing do
            :matching -> [mine, stranger]
            :none -> [stranger]
            :twice -> [mine, twin]
          end

        OperationsStub.json(conn, 200, %{"data" => data})
    end)
  end

  test "a lost answer is outcome_unknown after one send; reconciling asks and never re-sends",
       ctx do
    count = lossy_provider!(ctx.provider)
    row = invoke!(ctx.member, ctx.submission)
    assert row.status == :ready

    assert execute(row) == :outcome_unknown
    unknown = current(row)
    assert {unknown.status, unknown.error_code} == {:outcome_unknown, "ambiguous"}
    assert count.("POST", "/activations") == 1
    refute_received {:slept, _ms}

    # A redelivery of the execute finds a settled-for-now row and sends nothing.
    assert execute(row) == :skipped
    assert count.("POST", "/activations") == 1

    # The reconciler asks the provider by the invocation's key.
    assert reconcile(row) == :succeeded
    settled = current(row)

    assert {settled.status, settled.reconciled_via, settled.effect_ref, settled.effect_system} ==
             {:succeeded, "reconcile_with", "act-7", "battery-registry"}

    assert {count.("POST", "/activations"), count.("GET", "/activations")} == {1, 1}
    assert Agent.get(ctx.provider, & &1.accepted) == row.invocation_key

    # Reconciling again does nothing: the provider is not asked and the row is unchanged.
    assert reconcile(row) == :skipped
    assert count.("GET", "/activations") == 1
    assert current(row) == settled

    recorded_once!(row, ctx)
  end

  test "no match leaves the row outcome_unknown for a person, and sends nothing again", ctx do
    count = lossy_provider!(ctx.provider)
    Agent.update(ctx.provider, &%{&1 | listing: :none})
    row = invoke!(ctx.member, ctx.submission)
    assert execute(row) == :outcome_unknown

    assert reconcile(row) == :resolution_requested
    stays = current(row)
    assert stays.status == :outcome_unknown
    refute is_nil(stays.resolution_requested_at)
    assert count.("POST", "/activations") == 1
  end

  test "two matches are left to a person, with the lookup saying why", ctx do
    count = lossy_provider!(ctx.provider)
    Agent.update(ctx.provider, &%{&1 | listing: :twice})
    row = invoke!(ctx.member, ctx.submission)
    assert execute(row) == :outcome_unknown

    assert reconcile(row) == :resolution_requested
    assert current(row).status == :outcome_unknown
    assert count.("POST", "/activations") == 1

    answer =
      Submission
      |> Ash.ActionInput.for_action(
        :lookup_submission,
        %{id: ctx.submission.id, invocation_key: row.invocation_key},
        actor: ctx.member
      )
      |> Ash.run_action!()

    assert %{"outcome" => "unknown", "code" => "reconcile_many", "effect_ref" => nil} = answer
  end

  test "a 429 is transient, deferred and never outcome_unknown", ctx do
    count =
      lossy_provider!(ctx.provider, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> OperationsStub.json(429, %{"code" => "RATE_LIMITED", "requestId" => "req-1"})
      end)

    # Called directly, the typed error carries what the provider asked for.
    direct =
      Registry.create_activation(
        %{client_reference: "direct", disclosure_ref: ctx.submission.id},
        actor: ctx.member
      )

    assert {:error, error} = direct

    assert %{reason: :rate_limited, retry_after_ms: 2000, provider_code: "RATE_LIMITED"} =
             AshOperations.Error.unwrap(error)

    # The table waited the provider's two seconds (reported, never slept), then gave up.
    assert_received {:slept, 2000}
    sends = count.("POST", "/activations")
    assert sends > 1

    # Through an invocation it is transient, and the row is not outcome_unknown.
    row = invoke!(ctx.member, ctx.submission)
    assert execute(row) == :deferred
    deferred = current(row)
    refute deferred.status == :outcome_unknown

    assert {deferred.status, deferred.failure_class, deferred.error_code} ==
             {:ready, :transient, "rate_limited"}

    assert count.("POST", "/activations") > sends
  end

  # The transition to `succeeded` is recorded once in the event log and emitted once as
  # lineage, and the lineage names tables and jobs, never a person, a key or an id.
  defp recorded_once!(row, ctx) do
    events =
      EventLog
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.resource == Invocation and &1.record_id == row.id))

    assert [_one] = Enum.filter(events, &(&1.action == :complete_external))
    assert Enum.filter(events, &(&1.action == :succeed)) == []

    completes =
      Enum.filter(Capture.events(), fn {event, _meta} ->
        event["eventType"] == "COMPLETE" and
          event["job"]["name"] == "invocation.complete_external"
      end)

    assert [{event, _meta}] = completes

    leaked =
      for needle <- [ctx.member.id, row.id, row.invocation_key, "act-7", ctx.submission.id],
          inspect(Capture.events()) =~ needle,
          do: needle

    assert leaked == [], "lineage carried #{inspect(leaked)} in #{inspect(event)}"
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

  defp reconcile(row) do
    Invocation
    |> Ash.ActionInput.for_action(:reconcile, %{primary_key: %{"id" => row.id}})
    |> Ash.run_action!()
  end

  defp current(row), do: Ash.get!(Invocation, row.id)
end
