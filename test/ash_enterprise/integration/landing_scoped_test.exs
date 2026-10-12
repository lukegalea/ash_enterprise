defmodule AshEnterprise.Integration.LandingScopedTest do
  @moduledoc """
  The scoped lander (ADR 0024 wired into the Nango edge): one erasure scope per
  linked account, ref = the linked account's uuid; landings sealed under it,
  idempotent under it, refused under a shredded one, and never moved to
  another. Synthetic payloads only; no provider call is made.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{Scope, Shredded}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Landing, LinkedAccount, SourceRecord}
  alias AshEnterprise.Integration.Landing.Scoped
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActorContext

  @secret "SYNTHETIC-LANDING-SECRET quarterly churn"

  setup do
    unique = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Landing #{unique}",
        unique_name: "landing-#{unique}",
        email: "operator-#{unique}@landing.test"
      )

    actor =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    account =
      LinkedAccount.link!(
        %{provider_config_key: "slack", connection_id: "conn-synthetic-#{unique}", label: "work"},
        actor: actor,
        tenant: seeded.organization.id
      )

    %{actor: actor, account: account, org: seeded.organization}
  end

  test "the configured lander is the scoped one" do
    assert Landing.wired?()

    assert Application.get_env(:ash_enterprise, Landing)[:lander] == Scoped
  end

  test "one scope per linked account: kind connection, ref the account uuid, opaque label", ctx do
    assert Landing.scope(ctx.account) == ctx.account.id

    assert {:ok, %Scope{} = scope} = Landing.open(ctx.account)
    assert scope.kind == :connection
    assert scope.ref == ctx.account.id
    assert scope.label == "linked account (slack)"
    refute scope.label =~ "work"
    refute scope.ref =~ "conn-synthetic"

    # Opening again is a lookup, not a second scope.
    assert {:ok, %Scope{id: id}} = Landing.open(ctx.account)
    assert id == scope.id

    # The shred CLI's `connection:<ref>` resolves to the same scope.
    assert {:ok, %Scope{id: ^id}} =
             Erasure.scope_by_ref(:connection, ctx.account.id, authorize?: false)
  end

  test "lands sealed under the scope; re-landing is an idempotent upsert", ctx do
    {:ok, scope} = Landing.open(ctx.account)

    assert {:ok, first} = Landing.land(record(ctx, "a", @secret), scope: scope)
    assert first.erasure_scope_id == scope.id
    assert first.raw_payload == %{"text" => @secret}
    assert first.source_metadata["stream"] == "synthetic.stream"

    assert {:ok, again} = Landing.land(record(ctx, "a", @secret <> " v2"), scope: scope)
    assert again.id == first.id
    assert again.raw_payload == %{"text" => @secret <> " v2"}

    assert [_one] = sources()
    refute raw_payload_bytes(first.id) =~ "SYNTHETIC-LANDING-SECRET"
  end

  test "a bare ref is opened on the spot", ctx do
    assert {:ok, landed} =
             Landing.land(record(ctx, "b", @secret), scope: Landing.scope(ctx.account))

    {:ok, scope} = Landing.open(ctx.account)
    assert landed.erasure_scope_id == scope.id
  end

  test "a landing under a different scope never re-scopes the existing row", ctx do
    {:ok, scope} = Landing.open(ctx.account)
    assert {:ok, landed} = Landing.land(record(ctx, "shared", @secret), scope: scope)

    other =
      Erasure.ensure_scope!(:connection, Ecto.UUID.generate(), %{label: "other"},
        actor: AshEnterprise.Platform.SystemActor.oban()
      )

    assert {:error, :cross_scope_landing} =
             Landing.land(record(ctx, "shared", "SYNTHETIC-HIJACK"), scope: other)

    [row] = sources()
    assert row.id == landed.id
    assert row.erasure_scope_id == scope.id
    assert row.raw_payload == %{"text" => @secret}
  end

  test "a shredded scope refuses to open and refuses landings", ctx do
    {:ok, scope} = Landing.open(ctx.account)
    assert {:ok, _} = Landing.land(record(ctx, "c", @secret), scope: scope)

    Erasure.shred_scope!(scope, scope.ref, "test", actor: ctx.actor)

    assert {:error, :scope_shredded} = Landing.open(ctx.account)

    assert {:error, :scope_shredded} =
             Landing.land(record(ctx, "d", "SYNTHETIC-AFTER-SHRED"), scope: scope)

    [row] = sources()
    assert %Shredded{} = row.raw_payload
  end

  test "an unwired deployment refuses to open a scope", ctx do
    previous = Application.get_env(:ash_enterprise, Landing)
    Application.put_env(:ash_enterprise, Landing, lander: Landing.NotWired)
    on_exit(fn -> Application.put_env(:ash_enterprise, Landing, previous) end)

    refute Landing.wired?()
    assert {:error, :scoped_landing_not_wired} = Landing.open(ctx.account)

    assert {:error, :scoped_landing_not_wired} =
             Landing.land(record(ctx, "e", @secret), scope: "x")

    assert sources() == []
  end

  defp record(ctx, id, text) do
    %SourceRecord{
      external_system: "synthetic",
      external_id: "#{ctx.account.id}/#{id}",
      stream: "synthetic.stream",
      raw_payload: %{"text" => text},
      fetched_at: DateTime.utc_now(),
      source_metadata: %{"linked_account_id" => ctx.account.id}
    }
  end

  defp sources do
    SourceObject
    |> Ash.Query.filter(external_system == "synthetic")
    |> Ash.read!(authorize?: false)
  end

  defp raw_payload_bytes(id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT encrypted_raw_payload FROM ingestion_source_objects WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    value
  end
end
