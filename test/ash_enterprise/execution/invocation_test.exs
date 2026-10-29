defmodule AshEnterprise.Execution.InvocationTest do
  @moduledoc """
  The governed invocation on the platform (ADR 0055): what `invoke` and `request` record
  for a person, who may call which action, how the arguments are sealed, and that a
  request cannot attach itself to someone else's work.

  These run in the SQL sandbox. What needs commits seen by other connections (twenty
  concurrent invokes, a worker killed between commits, a lease taken over) is in the
  durability tier beside this file.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshAgent.Invocation.{IdempotencyConflict, NoPrincipal}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.Execution.Invocation.ExecuteWorker
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Test.Execution, as: Notes

  @record "AshEnterprise.Test.Execution.ClinicNote.record"
  @reviewed "AshEnterprise.Test.Execution.ClinicNote.record_reviewed"

  setup do
    admin = tenant!()
    # A member who holds no role at all: everything below reaches them through
    # self-service, never through a grant.
    nurse = member!(admin, "Nurse #{System.unique_integer([:positive])}", [])
    %{admin: admin, nurse: nurse}
  end

  defp key, do: "test:#{System.unique_integer([:positive])}"
  defp note(title), do: %{"title" => title}
  defp oban(ctx), do: [actor: SystemActor.oban(), tenant: ctx.tenant]

  defp invoke!(who, target, args, extra \\ %{}),
    do:
      Execution.invoke!(target, args, Map.put_new(extra, :key, key()),
        actor: who.actor,
        tenant: who.tenant
      )

  defp notes(tenant, title),
    do: Notes.list_notes!(query: [filter: [title: title]], tenant: tenant, authorize?: false)

  describe "invoke" do
    test "a member with no role records a ready request, owned and sealed", %{nurse: nurse} do
      row = invoke!(nurse, @record, note("Call the lab about the morning panel"))

      assert row.status == :ready
      assert row.owner_id == nurse.user.id
      assert row.executing_principal == %{type: :person, id: nurse.user.id}
      assert row.organization_id == nurse.tenant

      # Sealed under the requester's own erasure scope; no plaintext column.
      scope = Erasure.get_scope!(row.erasure_scope_id, authorize?: false)
      assert {scope.kind, scope.ref} == {:data_subject, "invocation_requester:#{nurse.user.id}"}
      assert is_binary(row.encrypted_args)
      refute row.encrypted_args =~ "morning panel"

      opened = Ash.load!(row, [:args], actor: SystemActor.oban(), tenant: nurse.tenant)
      assert opened.args == %{"title" => "Call the lab about the morning panel"}

      # The digest is keyed by the scope, not a plain hash of the arguments.
      {:ok, digest_key} = Execution.DigestKey.digest_key(row)
      assert row.args_digest == AshAgent.Digest.hmac_hex(digest_key, opened.args)
      refute row.args_digest == AshAgent.Digest.sha256_hex(opened.args)

      # Enqueued with the row, by id only.
      assert_enqueued(worker: ExecuteWorker, args: %{"primary_key" => %{"id" => row.id}})
    end

    test "the job runs the target as the requester, once", %{nurse: nurse} do
      row = invoke!(nurse, @record, note("Confirm tomorrow's first appointment"))

      assert %{success: 1} = Oban.drain_queue(queue: :execution)

      done = Execution.get_invocation!(row.id, oban(nurse))
      assert {done.status, done.lease_epoch} == {:succeeded, 1}

      assert [made] = notes(nurse.tenant, "Confirm tomorrow's first appointment")
      assert made.owner_id == nurse.user.id

      result = Ash.load!(done, [:result], oban(nurse)).result
      assert result == %{"resource" => "AshEnterprise.Test.Execution.ClinicNote", "id" => made.id}

      # The sweep finds nothing left to do, and a duplicate delivery claims nothing.
      assert :skipped = Execution.execute_invocation!(%{"id" => row.id}, oban(nurse))
      assert length(notes(nurse.tenant, "Confirm tomorrow's first appointment")) == 1
    end

    test "the same key returns the same row; different arguments are a conflict", %{nurse: nurse} do
      key = key()
      first = invoke!(nurse, @record, note("Restock the waiting room"), %{key: key})
      assert invoke!(nurse, @record, note("Restock the waiting room"), %{key: key}).id == first.id

      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{key: ^key}]}} =
               Execution.invoke(@record, note("Something else"), %{key: key},
                 actor: nurse.actor,
                 tenant: nurse.tenant
               )

      assert [%{id: id, args_digest: digest}] =
               Execution.list_invocations!(
                 Keyword.put(oban(nurse), :query, filter: [invocation_key: key])
               )

      assert {id, digest} == {first.id, first.args_digest}
    end

    test "the same key from another person is a conflict, not their row", %{
      admin: admin,
      nurse: nurse
    } do
      key = key()
      invoke!(nurse, @record, note("Restock the waiting room"), %{key: key})
      colleague = member!(admin, "Colleague #{System.unique_integer([:positive])}", [])

      assert {:error, %Ash.Error.Invalid{errors: [%IdempotencyConflict{}]}} =
               Execution.invoke(@record, note("Restock the waiting room"), %{key: key},
                 actor: colleague.actor,
                 tenant: colleague.tenant
               )
    end

    test "a target that asks for approval waits for one", %{nurse: nurse} do
      row = invoke!(nurse, @reviewed, note("Order more flu vaccine"))
      assert {row.status, row.approval_mode} == {:awaiting_approval, :confirm}
      refute_enqueued(worker: ExecuteWorker, args: %{"primary_key" => %{"id" => row.id}})
    end

    test "a system actor is not a principal", %{nurse: nurse} do
      assert {:error, %Ash.Error.Forbidden{errors: [%NoPrincipal{}]}} =
               Execution.invoke(@record, note("x"), %{key: key()}, oban(nurse))
    end

    test "a target with no effects declaration cannot be invoked", %{nurse: nurse} do
      assert {:error, %Ash.Error.Invalid{}} =
               Execution.invoke(
                 "AshEnterprise.Security.UserRole.destroy",
                 %{},
                 %{key: key()},
                 actor: nurse.actor,
                 tenant: nurse.tenant
               )
    end
  end

  describe "the parent" do
    test "a direct request naming someone else's parent is refused", %{admin: admin, nurse: nurse} do
      theirs = invoke!(admin, @record, note("Admin's own request"))
      mine = invoke!(nurse, @record, note("My own request"))

      request = fn parent ->
        Invocation
        |> Ash.Changeset.for_create(
          :request,
          %{
            target: @record,
            args: note("Follow-up"),
            invocation_key: key(),
            parent: parent
          },
          actor: nurse.actor,
          tenant: nurse.tenant
        )
        |> Ash.create()
      end

      assert {:error, %Ash.Error.Invalid{errors: errors}} = request.(%{invocation_id: theirs.id})
      assert Enum.any?(errors, &match?(%{field: :parent_invocation_id}, &1))

      assert {:error, %Ash.Error.Invalid{}} = request.(%{invocation_id: Ash.UUID.generate()})
      assert {:error, %Ash.Error.Invalid{}} = request.(%{run_id: Ash.UUID.generate()})

      assert {:ok, child} = request.(%{invocation_id: mine.id})
      assert child.parent_invocation_id == mine.id
    end

    test "invoke applies the same rule", %{admin: admin, nurse: nurse} do
      theirs = invoke!(admin, @record, note("Admin's own request"))

      assert {:error, %Ash.Error.Invalid{}} =
               Execution.invoke(
                 @record,
                 note("Follow-up"),
                 %{key: key(), parent: %{invocation_id: theirs.id}},
                 actor: nurse.actor,
                 tenant: nurse.tenant
               )
    end
  end

  describe "who may do what" do
    test "the machinery actions are the job runner's alone", %{nurse: nurse} do
      row = invoke!(nurse, @record, note("Call the pharmacy"))

      for action <- [:claim, :apply_decision] do
        refute Ash.can?({row, action}, nurse.actor, tenant: nurse.tenant)
        refute Ash.can?({row, action}, SystemActor.process(), tenant: nurse.tenant)
        assert Ash.can?({row, action}, SystemActor.oban(), tenant: nurse.tenant)
      end

      refute Ash.can?({Invocation, :execute}, nurse.actor, tenant: nurse.tenant)
      refute Ash.can?({Invocation, :execute}, SystemActor.process(), tenant: nurse.tenant)
      assert Ash.can?({Invocation, :execute}, SystemActor.oban(), tenant: nurse.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Execution.claim_invocation(row, actor: nurse.actor, tenant: nurse.tenant)
    end

    test "a member reads no invocation, not even their own, without a grant", %{nurse: nurse} do
      invoke!(nurse, @record, note("Call the pharmacy"))
      assert Execution.list_invocations!(actor: nurse.actor, tenant: nurse.tenant) == []
    end

    test "a new tenant's Administrator holds the invocation privileges" do
      seeded = Seeder.seed_tenant(unique_name: "exec-#{System.unique_integer([:positive])}")
      name = inspect(Invocation)

      granted =
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
        |> Ash.Query.load(:privilege)
        |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
        |> Enum.map(& &1.privilege.access_right)

      assert :read in granted
      assert :write in granted
    end
  end
end
