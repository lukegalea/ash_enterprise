defmodule AshEnterprise.Execution.PrecheckTest do
  @moduledoc """
  The request-time pre-check on the host (`AshAgent.Invocation.Target.precheck/3`, run
  by `request` once `AshEnterprise.Execution.Identity` answers `precheck_actor/1`): a
  live request is checked against its action, as the principal it will execute as,
  before its row is stored.

    * the action's own refusal — a validation, a change, a transition — rejects the row
      as `invalid_request` with each input's message in `rejection_details`, sealed
      under the row's erasure scope like `args`;
    * a principal who may not make the change is rejected as `not_permitted`, which
      says no more than that;
    * nobody is asked to approve a refusal: no approval task opens, nothing is
      enqueued, nothing runs.

  A refusal only the running action can find (a hook, an outside call) is still an
  execution-time failure — `typed_failure_test.exs`. Another tenant's records are
  refused exactly as missing ones are, here as in `prepare/3` before the pre-check.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]
  import AshEnterprise.Test.Execution.Runs, only: [clinic!: 0, published!: 1, start: 1]

  require Ash.Query

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Invocation.ExecuteWorker
  alias AshEnterprise.Security
  alias AshEnterprise.Security.UserRole
  alias AshEnterprise.Test.Execution, as: Notes

  @screened "AshEnterprise.Test.Execution.ClinicNote.record_screened"
  @retitle "AshEnterprise.Test.Execution.ClinicNote.retitle"
  @assign "AshEnterprise.Security.UserRole.assign_governed"

  setup do
    admin = tenant!()
    # A member who holds no role at all: everything self-service reaches them through
    # that alone, and nothing granted does.
    nurse = member!(admin, "Nurse #{System.unique_integer([:positive])}", [])
    %{admin: admin, nurse: nurse}
  end

  defp key, do: "test:#{System.unique_integer([:positive])}"
  defp note(title), do: %{"title" => title}
  defp oban(ctx), do: [actor: AshEnterprise.Platform.SystemActor.oban(), tenant: ctx.tenant]

  defp invoke!(who, target, args),
    do: Execution.invoke!(target, args, %{key: key()}, actor: who.actor, tenant: who.tenant)

  defp notes(tenant, title),
    do: Notes.list_notes!(query: [filter: [title: title]], tenant: tenant, authorize?: false)

  defp roles_of(user, tenant),
    do:
      UserRole
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false, tenant: tenant)

  describe "the action's own refusal moves to request time" do
    test "a validation the pre-check runs rejects the row, sealed, and asks no one", %{
      nurse: nurse
    } do
      title = "DECLINED: cosmetic referral #{System.unique_integer([:positive])}"

      row = invoke!(nurse, @screened, note(title))

      assert {row.status, row.failure_class, row.error_code} ==
               {:rejected, :rejected, "invalid_request"}

      # Sealed under the row's erasure scope like `args`: ciphertext in its column,
      # the plaintext only on a read (the preparation that opens it).
      assert row.erasure_scope_id
      assert is_binary(row.encrypted_rejection_details)
      refute row.encrypted_rejection_details =~ "DECLINED"

      # The package's own column stays empty: the sealing clears the pending change.
      assert %{rows: [[nil]]} =
               AshEnterprise.Repo.query!(
                 "SELECT rejection_details FROM exec_invocations WHERE id = $1",
                 [Ecto.UUID.dump!(row.id)]
               )

      read = Execution.get_invocation!(row.id, oban(nurse))

      assert [%{"message" => message}] = read.rejection_details["errors"]
      assert message =~ "refused by a business rule: declined_by_clinic"

      # A refusal runs nothing and asks nobody: no job, no effect, and no retry.
      refute_enqueued(worker: ExecuteWorker)
      assert notes(nurse.tenant, title) == []
      assert {:error, _} = Execution.retry_invocation(read, oban(nurse))
    end
  end

  describe "permission" do
    test "a principal without the grant is refused at request time, saying no more", %{
      admin: admin,
      nurse: nurse
    } do
      newbie = member!(admin, "Newbie #{System.unique_integer([:positive])}", [])

      # Any role id the action would take: the refusal is the principal's, and is
      # not about the arguments at all.
      [role | _] = Security.Role |> Ash.read!(authorize?: false, tenant: admin.tenant)

      row =
        invoke!(nurse, @assign, %{
          "user_id" => newbie.user.id,
          "role_id" => role.id
        })

      assert {row.status, row.failure_class, row.error_code} ==
               {:rejected, :rejected, "not_permitted"}

      # A refusal of permission says never why, and never whether a record exists.
      read = Execution.get_invocation!(row.id, oban(nurse))
      assert read.rejection_details == %{"errors" => [%{"message" => "not permitted"}]}

      # Nothing ran: the role the request named was not assigned (the member's own
      # empty-privilege role, from `member!`, is the only one they hold).
      refute Enum.any?(roles_of(newbie.user, admin.tenant), &(&1.role_id == role.id))
      refute_enqueued(worker: ExecuteWorker)
    end
  end

  describe "another tenant's records" do
    test "are refused exactly as missing ones are, and are not reached through the pre-check",
         %{admin: admin, nurse: nurse} do
      title = "Discuss the audit findings #{System.unique_integer([:positive])}"

      theirs =
        Notes.ClinicNote
        |> Ash.Changeset.for_create(:record, %{title: title},
          actor: admin.actor,
          tenant: admin.tenant
        )
        |> Ash.create!()

      other = tenant!()
      stranger = member!(other, "Stranger #{System.unique_integer([:positive])}", [])

      hidden = invoke!(stranger, @retitle, %{"id" => theirs.id, "title" => "x"})
      missing = invoke!(stranger, @retitle, %{"id" => Ash.UUID.generate(), "title" => "x"})

      outcome = &Map.take(&1, [:status, :failure_class, :error_code])
      assert outcome.(hidden) == outcome.(missing)
      assert hidden.status == :rejected

      # The note they named played no part: it still stands as its owner wrote it.
      assert [note_row] = notes(admin.tenant, title)
      assert note_row.id == theirs.id
      assert notes(other.tenant, title) == []
    end
  end

  describe "the pre-check actor for a run's tool call" do
    setup %{admin: _admin} do
      clinic = clinic!()
      %{clinic: clinic, version: published!(clinic)}
    end

    # The row as `request` hands it to `precheck_actor/1`: every attribute it has set,
    # lineage and tenant included, and no primary key yet.
    defp unwritten(run, person_id),
      do: %Invocation{
        id: nil,
        run_id: run.id,
        organization_id: run.organization_id,
        executing_principal: %{type: :person, id: person_id}
      }

    test "is built from the run's agent grant, from a row with no id yet", %{
      clinic: clinic,
      version: _version
    } do
      {:ok, run} = start(clinic.nurse)

      assert {:ok, actor} = Identity.precheck_actor(unwritten(run, clinic.nurse.user.id))
      assert actor.id == clinic.nurse.user.id

      # The tenant's administrator holds no start grant for this agent: the run's
      # agent is whose grant decides, not the person's own standing.
      assert {:error, :no_start_grant} =
               Identity.precheck_actor(unwritten(run, clinic.admin.user.id))

      # And the starter is held to it as they are at the request, not as they were.
      for grant <-
            Security.AgentStartGrant.read!(actor: clinic.admin.actor, tenant: clinic.tenant) do
        Security.AgentStartGrant.destroy!(grant, actor: clinic.admin.actor, tenant: clinic.tenant)
      end

      assert {:error, :no_start_grant} =
               Identity.precheck_actor(unwritten(run, clinic.nurse.user.id))
    end
  end
end
