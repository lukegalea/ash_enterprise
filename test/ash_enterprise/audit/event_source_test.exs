defmodule AshEnterprise.Audit.EventSourceTest do
  @moduledoc """
  The adapter's contract with the engine, as assertions.

  `AshBpmn.EventSource` is the seam the whole trigger engine crosses to reach
  this application's audit log, so the interesting tests are the ones pinning
  the *published* parts of the contract: the context shape every tenant's
  guards evaluate against, the per-chain ordering declaration, and what
  "audited" means when the publish-time refusal asks. The engine's own
  behaviour over the contract is `ash_bpmn`'s `triggers_runtime_test` and is
  deliberately not duplicated here.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Audit.{EventLog, EventSource}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.Role

  setup do
    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        unique_name: "esrc-#{System.unique_integer([:positive])}",
        email: "esrc-#{System.unique_integer([:positive])}@example.com"
      )

    %{tenant: organization.id, admin: admin}
  end

  defp create_role!(tenant, name) do
    Role
    |> Ash.Changeset.for_create(:create, %{name: name},
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  defp latest_sequence(tenant) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{sequence: sequence}] -> sequence
      [] -> 0
    end
  end

  defp latest_event!(tenant, resource) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(resource == ^resource)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  describe "stream/3" do
    test "streams ascending from a sequence, bounded", %{tenant: tenant} do
      create_role!(tenant, "stream-a-#{System.unique_integer()}")
      create_role!(tenant, "stream-b-#{System.unique_integer()}")
      create_role!(tenant, "stream-c-#{System.unique_integer()}")

      assert {:ok, {events, last}} = EventSource.stream(tenant, 0, 2)
      assert length(events) == 2
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences), "a batch must be ascending"
      assert last == List.last(events).sequence

      # Resume exactly where the batch ended — the cursor protocol. Nothing from
      # the first batch reappears, and reading past the end is an empty batch
      # that keeps the cursor where it is.
      first_batch_ids = Enum.map(events, & &1.id)

      assert {:ok, {rest, _}} = EventSource.stream(tenant, last, 10)

      refute Enum.any?(rest, &(&1.id in first_batch_ids)),
             "a resumed stream must never replay the batch it resumed from"

      assert {:ok, {[], nil}} = EventSource.stream(tenant, latest_sequence(tenant), 10)
    end

    test "one tenant's chain is that tenant's events and nothing else", %{
      tenant: tenant
    } do
      %{organization: other} =
        Seeder.seed_tenant(
          unique_name: "esrc-other-#{System.unique_integer([:positive])}",
          email: "esrc-other-#{System.unique_integer([:positive])}@example.com"
        )

      create_role!(tenant, "mine-#{System.unique_integer()}")
      create_role!(other.id, "theirs-#{System.unique_integer()}")

      {:ok, {events, _}} = EventSource.stream(tenant, 0, 100)

      assert events != []

      assert Enum.all?(events, &(&1.organization_id == tenant)),
             "streaming a tenant must never leak another tenant's chain"
    end

    # The NULL-tenant chain is a chain of its own. The log's multitenancy is
    # `global? true`, so a nil-tenant read *could* see everything — which is
    # exactly the global cursor the design refuses, and why the adapter
    # filters it to `organization_id IS NULL` explicitly. The events come from
    # a `tenant?: false` resource: an `Organization`, whose writes carry no
    # tenant and so land on the NULL chain.
    test "a nil tenant streams the NULL chain, not everything", %{tenant: tenant} do
      create_role!(tenant, "scoped-#{System.unique_integer()}")

      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(
        :create,
        %{
          unique_name: "esrc-null-#{System.unique_integer([:positive])}",
          name: "Null chain probe"
        },
        actor: SystemActor.seed()
      )
      |> Ash.create!()

      {:ok, {nil_chain, _}} = EventSource.stream(nil, 0, 100)

      assert nil_chain != []

      assert Enum.all?(nil_chain, &is_nil(&1.organization_id)),
             "a nil-tenant stream must be the NULL chain alone"
    end
  end

  describe "context/1 — the published contract" do
    test "the shape guards and decisions read", %{tenant: tenant, admin: admin} do
      # Created by the admin, so the human attribution is in the event.
      role =
        Role
        |> Ash.Changeset.for_create(:create, %{name: "ctx-#{System.unique_integer()}"},
          actor: admin,
          tenant: tenant
        )
        |> Ash.create!()

      event = latest_event!(tenant, Role)

      context = EventSource.context(event)

      assert MapSet.new(Map.keys(context)) ==
               MapSet.new(["event", "actor", "tenant", "data", "changed", "metadata"])

      assert context["event"]["id"] == event.id
      assert context["event"]["sequence"] == event.sequence
      assert context["event"]["occurred_at"] == event.occurred_at
      assert context["event"]["action"] == "create"
      assert context["event"]["action_type"] == "create"
      assert context["event"]["record_id"] == role.id
      assert context["event"]["version"] == event.version

      # The short spelling — what a person types and what a FEEL guard compares
      # against, never the `Elixir.`-prefixed form the column stores.
      assert context["event"]["resource"] == "AshEnterprise.Security.Role"

      # The human who caused the write, and the tenant it happened in.
      assert context["actor"]["user_id"] == admin.id
      assert context["actor"]["system_actor"] == nil
      assert context["tenant"]["organization_id"] == tenant

      # `data` is the event's snapshot of the record — a guard reads what
      # happened, not what is now true.
      assert context["data"]["name"] == role.name
    end

    test "a system write attributes the system actor, not a user", %{tenant: tenant} do
      create_role!(tenant, "sys-#{System.unique_integer()}")
      event = latest_event!(tenant, Role)

      context = EventSource.context(event)

      assert context["actor"]["user_id"] == nil
      assert context["actor"]["system_actor"] == "seed"
    end

    test "resource names normalize from every spelling the log can produce", %{
      tenant: tenant
    } do
      event = latest_event!(tenant, Role)
      from_atom = EventSource.context(%{event | resource: Role})
      from_short = EventSource.context(%{event | resource: "AshEnterprise.Security.Role"})

      from_prefixed =
        EventSource.context(%{event | resource: "Elixir.AshEnterprise.Security.Role"})

      assert from_atom["event"]["resource"] == "AshEnterprise.Security.Role"
      assert from_short["event"]["resource"] == from_atom["event"]["resource"]
      assert from_prefixed["event"]["resource"] == from_atom["event"]["resource"]
    end
  end

  describe "order_guarantee/1 — a declaration, not a measurement" do
    test "a real tenant claims commit order" do
      %{organization: organization} =
        Seeder.seed_tenant(
          unique_name: "esrc-og-#{System.unique_integer([:positive])}",
          email: "esrc-og-#{System.unique_integer([:positive])}@example.com"
        )

      assert EventSource.order_guarantee(organization.id) == :commit_order
    end

    # The NULL-tenant chain shares no lock space with anything — a two-argument
    # `pg_advisory_xact_lock` against a one-argument one — so it has no
    # ordering guarantee to weaken, and the adapter must not pretend it does.
    test "the NULL chain claims best effort" do
      assert EventSource.order_guarantee(nil) == :best_effort
    end
  end

  describe "audited?/1 — what the publish-time refusal asks" do
    test "an audited resource writing to this log is audited" do
      assert EventSource.audited?(Role)
      assert EventSource.audited?(AshEnterprise.Bpmn.Definition)
      assert EventSource.audited?(AshEnterprise.Accounts.User)
    end

    test "a resource with no audit hook is not" do
      refute EventSource.audited?(AshEnterprise.Legacy.User),
             "the strangler's read model writes no events; a subscription on it waits forever"
    end

    test "a name that is not a resource is not" do
      refute EventSource.audited?(NoSuch.Resource.Anywhere)
    end
  end

  test "the engine is wired to this adapter, and the log carries its nudge" do
    assert Application.get_env(:ash_bpmn, :event_source) == AshEnterprise.Audit.EventSource
    assert AshBpmn.Triggers.Nudge in Ash.Resource.Info.notifiers(EventLog)
  end
end
