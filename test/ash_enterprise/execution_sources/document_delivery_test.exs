defmodule AshEnterprise.ExecutionSources.DocumentDeliveryTest do
  @moduledoc """
  A process run's webhook deliveries on the execution trace, on the seeded clinic: a
  delivery is an entry on the timeline under the run, read as the viewer in their tenant;
  a delivery sent twice is the one row the handler recorded, never two entries; no
  envelope data beyond the kind of document reaches an entry or its detail. SYNTHETIC
  data only.
  """

  use AshEnterprise.DataCase, async: false

  @moduletag evidence: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Bpmn.Instance
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{DemoData, DocumentEvent, DocumentWebhook}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Explorer
  alias AshEnterprise.Security.ActorContext

  setup do
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    credential = clinic.case_credential
    coordinator = actor(clinic.coordinator, admin.tenant)

    Credentialing.open_case!(credential.id, actor: coordinator, tenant: admin.tenant)

    instance =
      Instance
      |> Ash.read!(authorize?: false, tenant: admin.tenant)
      |> Enum.find(&(to_string(&1.subject_id) == credential.id))

    delivery = "delivery-#{System.unique_integer([:positive])}"
    assert DocumentWebhook.deliver(admin.tenant, credential.id, delivery) == :received
    assert DocumentWebhook.deliver(admin.tenant, credential.id, delivery) == :duplicate

    %{
      admin: admin,
      tenant: admin.tenant,
      coordinator: coordinator,
      instance: instance,
      delivery_id: delivery
    }
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp trace!(ref, viewer, tenant),
    do: Execution.trace!(%{root_ref: ref}, actor: viewer, tenant: tenant)

  defp deliveries(%{entries: entries}),
    do: Enum.filter(entries, &(&1.source == :document_delivery))

  test "a delivery is on the timeline under its run, once, however often it was sent", ctx do
    trace = trace!("process_instance:#{ctx.instance.id}", ctx.admin.actor, ctx.tenant)

    assert [entry] = deliveries(trace)
    assert entry.parent_ref == "process_instance:#{ctx.instance.id}"
    assert entry.summary == "document received: certificate"
    assert entry.status == :succeeded

    # In time order with the run's own history.
    assert trace.entries == Enum.sort_by(trace.entries, & &1.at, DateTime)

    # Nothing in the entry carries the envelope or a request's body or headers.
    refute inspect(entry) =~ ctx.delivery_id
    refute inspect(entry) =~ DocumentWebhook.source()
  end

  test "its detail names the document, sender and arrival, and nothing else", ctx do
    [entry] =
      ctx.instance.id
      |> then(&trace!("process_instance:#{&1}", ctx.admin.actor, ctx.tenant))
      |> deliveries()

    assert {:ok, detail} =
             Explorer.detail(entry.source_ref, actor: ctx.admin.actor, tenant: ctx.tenant)

    assert detail.type == :document_delivery
    assert detail.document_kind == "certificate"
    assert detail.delivery_id == ctx.delivery_id
    assert %DateTime{} = detail.received_at

    assert Map.keys(detail) -- [:type, :id, :delivery_id, :sender, :document_kind, :received_at] ==
             []
  end

  test "another tenant sees none of it, by trace or by detail", ctx do
    [entry] =
      ctx.instance.id
      |> then(&trace!("process_instance:#{&1}", ctx.admin.actor, ctx.tenant))
      |> deliveries()

    other = tenant!()

    assert deliveries(trace!("process_instance:#{ctx.instance.id}", other.actor, other.tenant)) ==
             []

    assert Explorer.detail(entry.source_ref, actor: other.actor, tenant: other.tenant) ==
             :unreadable
  end

  test "a viewer who may read deliveries but not the process sees none", ctx do
    reader =
      member!(ctx.admin, "Deliveries #{System.unique_integer([:positive])}", [
        {DocumentEvent, :read, :global}
      ])

    [entry] =
      ctx.instance.id
      |> then(&trace!("process_instance:#{&1}", ctx.admin.actor, ctx.tenant))
      |> deliveries()

    assert deliveries(trace!("process_instance:#{ctx.instance.id}", reader.actor, ctx.tenant)) ==
             []

    assert Explorer.detail(entry.source_ref, actor: reader.actor, tenant: ctx.tenant) ==
             :unreadable
  end

  test "the handler keeps one row for a repeat, so one is all the trace can show", ctx do
    rows = Ash.read!(DocumentEvent, authorize?: false, tenant: ctx.tenant)
    assert Enum.count(rows, &(&1.event_id == ctx.delivery_id)) == 1
  end
end
