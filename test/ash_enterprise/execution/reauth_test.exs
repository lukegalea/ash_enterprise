defmodule AshEnterprise.Execution.ReauthTest do
  @moduledoc """
  Invariant 10, reauthorization (ADR 0055, ADR 0043): an invocation runs on the
  authority its principal holds when it is claimed, rebuilt from grant rows then, never
  on what the requester could do when they asked.

  Each test requests work, commits it, takes authority away (a role, an account, a
  tenant, a start grant), and only then claims and runs the row, with the `:execution`
  queue paused so nothing runs early. The row must fail as `:denied` and the target
  must never run: a note's title is the committed effect, and it stays as it was.
  """

  use AshEnterprise.DurabilityCase, async: false

  import AshEnterprise.Test.Execution.Authority
  import AshEnterprise.Test.Execution.Durable

  require Ash.Query

  alias AshAgent.Invocation.Executor
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Security
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.ClinicNote

  @agent "note-tidier"

  setup do
    pause_execution!()
    clinic = clinic!()
    %{admin: admin} = clinic
    Map.put(clinic, :keeper, note_keeper!(admin, :basic))
  end

  defp retitle!(member, note, title) do
    key = "reauth:#{System.unique_integer([:positive])}"
    {:ok, row} = invoke(member, retitle_target(), %{"id" => note.id, "title" => title}, key)
    row
  end

  defp run(row, tenant), do: Executor.execute(Invocation, row.id, oban(tenant))
  defp current(row, tenant), do: Execution.get_invocation!(row.id, oban(tenant))

  defp outcome(row, tenant) do
    row = current(row, tenant)
    {row.status, row.failure_class, row.error_code}
  end

  describe "a person" do
    test "whose role is revoked between request and claim: denied, and the target never runs",
         %{keeper: keeper, tenant: tenant} do
      note = note!(keeper, "Check the defibrillator")

      # With the role, the same request runs.
      done = retitle!(keeper, note, "Checked the defibrillator")
      assert {:ok, :succeeded} = run(done, tenant)
      assert title(tenant, note.id) == "Checked the defibrillator"

      row = retitle!(keeper, note, "Replace the defibrillator pads")
      assert current(row, tenant).status == :ready

      revoke_roles!(keeper)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "forbidden"}
      assert title(tenant, note.id) == "Checked the defibrillator"
    end

    test "whose account is deactivated between request and claim: denied before the target is tried",
         %{keeper: keeper, tenant: tenant} do
      note = note!(keeper, "Order the flu vaccine")
      row = retitle!(keeper, note, "Order twice the flu vaccine")

      DailyFixtures.deactivate!(keeper)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "no_authority: inactive"}
      assert title(tenant, note.id) == "Order the flu vaccine"
    end

    test "who moves to another clinic between request and claim is not run in the old one",
         %{keeper: keeper, tenant: tenant} do
      note = note!(keeper, "Book the interpreter")
      row = retitle!(keeper, note, "Book two interpreters")

      # Their role rows in this clinic are untouched; their membership is not.
      move_to!(keeper, clinic!().admin)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "no_authority: other_tenant"}
      assert title(tenant, note.id) == "Book the interpreter"
    end

    test "asking to act on another clinic's record: refused, and nothing runs anywhere",
         %{keeper: keeper, tenant: tenant} do
      elsewhere = clinic!()
      theirs = note!(elsewhere.admin, "Their rota")

      row = retitle!(keeper, theirs, "Our rota now")
      assert {row.status, row.failure_class} == {:rejected, :rejected}

      assert {:ok, :skipped} = run(row, tenant)
      assert title(elsewhere.tenant, theirs.id) == "Their rota"
    end
  end

  describe "an automation principal acting for a person" do
    setup %{admin: admin, keeper: keeper} do
      principal_role =
        automation_role!(admin, :evidence_admitter, [
          {ClinicNote, :read, :global},
          {ClinicNote, :write, :global}
        ])

      start = start_grant!(admin, keeper, @agent)

      %{
        principal_role: principal_role,
        start: start,
        asking: starting(keeper, :evidence_admitter, @agent)
      }
    end

    test "runs as the principal for the person, and the audit trail says so",
         %{asking: asking, keeper: keeper, tenant: tenant} do
      note = note!(keeper, "Restock the sharps bins")
      row = retitle!(asking, note, "Restocked the sharps bins")

      assert {:ok, :succeeded} = run(row, tenant)
      assert title(tenant, note.id) == "Restocked the sharps bins"

      # The person is who the record names; the principal and the invocation are in
      # the audit entry beside them.
      written = Ash.get!(ClinicNote, note.id, tenant: tenant, authorize?: false)
      assert written.modified_by_id == keeper.user.id

      [event] =
        EventLog
        |> Ash.Query.filter(record_id == ^note.id and action == :retitle)
        |> Ash.read!(authorize?: false)

      assert Map.take(event.metadata, [
               "automation_principal",
               "on_behalf_of_id",
               "invocation_key"
             ]) ==
               %{
                 "automation_principal" => "evidence_admitter",
                 "on_behalf_of_id" => keeper.user.id,
                 "invocation_key" => row.invocation_key
               }
    end

    test "can do only what both allow: the principal's wider grant does not widen the person's",
         %{admin: admin, tenant: tenant} do
      # Reads every note, but may retitle only their own. The principal may retitle any.
      reader =
        DailyFixtures.member!(admin, "Reader #{System.unique_integer([:positive])}", [
          {ClinicNote, :read, :global},
          {ClinicNote, :write, :basic}
        ])

      start_grant!(admin, reader, @agent)
      asking = starting(reader, :evidence_admitter, @agent)

      theirs = note!(admin, "Admin's handover")
      own = note!(reader, "Reader's handover")

      denied = retitle!(asking, theirs, "Rewritten by the agent")
      allowed = retitle!(asking, own, "Tidied by the agent")
      assert current(denied, tenant).status == :ready

      assert {:ok, :failed} = run(denied, tenant)
      assert outcome(denied, tenant) == {:failed, :denied, "forbidden"}
      assert title(tenant, theirs.id) == "Admin's handover"

      assert {:ok, :succeeded} = run(allowed, tenant)
      assert title(tenant, own.id) == "Tidied by the agent"
    end

    test "whose own role is revoked between request and claim: denied, the target never runs",
         %{asking: asking, keeper: keeper, principal_role: principal_role, tenant: tenant} do
      note = note!(keeper, "File the incident report")
      row = retitle!(asking, note, "Filed the incident report")

      Security.AutomationRole.destroy!(principal_role, authorize?: false, tenant: tenant)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "forbidden"}
      assert title(tenant, note.id) == "File the incident report"
    end

    test "whose person's role is revoked between request and claim: denied, the target never runs",
         %{asking: asking, keeper: keeper, tenant: tenant} do
      note = note!(keeper, "Call the lab")
      row = retitle!(asking, note, "Called the lab")

      revoke_roles!(keeper)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "forbidden"}
      assert title(tenant, note.id) == "Call the lab"
    end

    test "whose start grant is revoked between request and claim: denied before the target is tried",
         %{asking: asking, keeper: keeper, start: start, tenant: tenant} do
      note = note!(keeper, "Renew the oxygen contract")
      row = retitle!(asking, note, "Renewed the oxygen contract")

      Security.AgentStartGrant.destroy!(start, authorize?: false, tenant: tenant)

      assert {:ok, :failed} = run(row, tenant)
      assert outcome(row, tenant) == {:failed, :denied, "no_authority: no_start_grant"}
      assert title(tenant, note.id) == "Renew the oxygen contract"
    end
  end
end
