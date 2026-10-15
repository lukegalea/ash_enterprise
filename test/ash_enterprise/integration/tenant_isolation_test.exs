defmodule AshEnterprise.Integration.TenantIsolationTest do
  @moduledoc """
  Two tenants, each with a seeded Administrator; tenant B links a provider
  account and lands one synthetic record. Tenant A's Administrator must reach
  none of it: not B's raw landing (untenanted, decrypted on read), not B's
  erasure scope (untenanted, and a shred is irreversible), not B's Nango
  connection id (which whoever reads it can spend). The operator-only
  privileges are reserved for the platform operator role
  (`Seeder.grant_platform_operator/1`), and no tenant role can be granted them
  by anyone but a system actor. Synthetic data only; no provider call.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Landing, LinkedAccount, SourceRecord}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @secret "SYNTHETIC-TENANT-B-PRIVATE-BODY"
  @connection "conn-victim-b-synthetic-0001"

  setup do
    a = tenant("a")
    b = tenant("b")

    account =
      LinkedAccount.link!(%{provider_config_key: "google-mail", connection_id: @connection},
        actor: b.actor,
        tenant: b.org.id
      )

    {:ok, scope} = Landing.open(account)

    {:ok, _} =
      Landing.land(
        %SourceRecord{
          external_system: "gmail",
          external_id: "#{account.id}:m-1",
          stream: "gmail.messages",
          raw_payload: %{"snippet" => @secret},
          fetched_at: DateTime.utc_now(),
          source_metadata: %{"linked_account_id" => account.id}
        },
        scope: scope
      )

    %{a: a, b: b, account: account, scope: scope}
  end

  test "an Administrator holds no operator-only privilege, seeded or regranted", ctx do
    Seeder.regrant_administrator_privileges(ctx.a.org.id)
    context = ActorContext.build(ctx.a.user, tenant: ctx.a.org.id)

    for resource <- [SourceObject, Scope, AshEnterprise.Erasure.Key],
        verb <- Security.AccessRight.verbs() do
      refute ActorContext.grant(context, resource, verb).global?,
             "Administrator holds #{verb} on #{inspect(resource)}"
    end
  end

  test "another tenant's Administrator reads none of B's raw landings", ctx do
    assert [_b_row] = SourceObject.by_system!("gmail", authorize?: false)

    rows =
      SourceObject
      |> Ash.Query.for_read(:read, %{}, actor: ctx.a.actor)
      |> Ash.read!()

    assert rows == []
  end

  test "another tenant's Administrator can neither read nor shred B's scope", ctx do
    assert {:ok, []} =
             Scope
             |> Ash.Query.filter(id == ^ctx.scope.id)
             |> Ash.read(actor: ctx.a.actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Erasure.shred_scope(ctx.scope, ctx.scope.ref, "not mine", actor: ctx.a.actor)

    assert {:error, _} =
             Erasure.ensure_scope(:connection, Ecto.UUID.generate(), %{label: "pre-open"},
               actor: ctx.a.actor
             )

    assert %Scope{status: :active} =
             Erasure.get_scope!(ctx.scope.id, authorize?: false)
  end

  test "an Administrator cannot grant themselves an operator-only privilege", ctx do
    scope_write =
      Security.Privilege
      |> Ash.Query.filter(resource_name == ^inspect(Scope) and access_right == :write)
      |> Ash.read_one!(authorize?: false)

    assert {:error, %Ash.Error.Invalid{} = error} =
             Security.RolePrivilege
             |> Ash.Changeset.for_create(
               :create,
               %{role_id: ctx.a.role.id, privilege_id: scope_write.id, depth: :global},
               actor: ctx.a.actor,
               tenant: ctx.a.org.id
             )
             |> Ash.create()

    assert Exception.message(error) =~ "reserved for the platform operator"
  end

  test "the platform operator alone can shred, in any tenant", ctx do
    Seeder.grant_platform_operator(ctx.a.user)
    operator = actor(ctx.a.user, ctx.a.org.id)

    assert {:ok, %Scope{status: :shredded}} =
             Erasure.shred_scope(ctx.scope, ctx.scope.ref, "operator erasure", actor: operator)
  end

  test "a deploy's seed removes operator-only grants an Administrator already holds", ctx do
    source_read =
      Security.Privilege
      |> Ash.Query.filter(resource_name == ^inspect(SourceObject) and access_right == :read)
      |> Ash.read_one!(authorize?: false)

    # A tenant provisioned before the privileges were reserved.
    Security.RolePrivilege
    |> Ash.Changeset.for_create(
      :create,
      %{role_id: ctx.a.role.id, privilege_id: source_read.id, depth: :global},
      actor: SystemActor.seed(),
      tenant: ctx.a.org.id
    )
    |> Ash.create!()

    assert [_] =
             SourceObject |> Ash.Query.for_read(:read, %{}, actor: actor(ctx.a)) |> Ash.read!()

    Seeder.seed_privileges()

    assert [] = SourceObject |> Ash.Query.for_read(:read, %{}, actor: actor(ctx.a)) |> Ash.read!()
  end

  test "another tenant's Administrator never sees B's connection id", ctx do
    for opts <- [[actor: ctx.a.actor], [actor: ctx.a.actor, tenant: ctx.b.org.id]] do
      for row <- LinkedAccount |> Ash.Query.for_read(:read, %{}, opts) |> Ash.read!() do
        assert %Ash.ForbiddenField{} = row.connection_id
      end
    end

    # Nor does B's own Administrator through a plain read: only the owner's
    # own reads (`:mine`, `:for_operation`) carry it.
    [own] = Ash.read!(LinkedAccount, actor: ctx.b.actor, tenant: ctx.b.org.id)
    assert %Ash.ForbiddenField{} = own.connection_id

    assert {:ok, [mine]} =
             LinkedAccount.mine(nil, %{}, actor: ctx.b.actor, tenant: ctx.b.org.id)

    assert mine.connection_id == @connection
  end

  test "a connection is linked once in the whole deployment", ctx do
    assert {:error, %Ash.Error.Invalid{}} =
             LinkedAccount.link(%{provider_config_key: "google-mail", connection_id: @connection},
               actor: ctx.a.actor,
               tenant: ctx.a.org.id
             )

    assert {:ok, []} =
             LinkedAccount.for_operation("google-mail", nil,
               actor: ctx.a.actor,
               tenant: ctx.a.org.id
             )
  end

  # --- helpers ------------------------------------------------------------------

  defp tenant(name) do
    unique = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Isolation #{name} #{unique}",
        unique_name: "isolation-#{name}-#{unique}",
        email: "admin-#{name}-#{unique}@isolation.synthetic.test"
      )

    %{
      org: seeded.organization,
      user: seeded.user,
      role: seeded.role,
      actor: actor(seeded.user, seeded.organization.id)
    }
  end

  defp actor(%{user: user, org: org}), do: actor(user, org.id)

  defp actor(user, org_id),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: org_id))
end
