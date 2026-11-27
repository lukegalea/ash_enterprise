defmodule AshEnterprise.Provenance.DemoDataTest do
  @moduledoc """
  The demo tenant's provenance seed (`AshEnterprise.Provenance.DemoData`): it runs through the
  application's own actions, a second fill changes nothing, and every address it hands out
  explains for the reader and is not found for the person who holds no read grant.
  SYNTHETIC data only; `scripts/provenance-demo.sh` walks the demo steps over it.
  """

  use AshEnterprise.DataCase, async: false

  # The judged facts cite documents in the evidence store.
  @moduletag evidence: true

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.DemoTenant
  alias AshEnterprise.Provenance
  alias AshEnterprise.Provenance.DemoData

  setup do
    %{organization: organization} = DemoTenant.run!()
    tenant = organization.id

    admin =
      User
      |> Ash.Query.filter(email == ^DemoTenant.admin_email())
      |> Ash.read_one!(authorize?: false)

    %{
      tenant: tenant,
      admin: admin,
      reader: DemoData.actor!(DemoData.reader_email(), tenant),
      viewer: DemoData.actor!(DemoData.viewer_email(), tenant)
    }
  end

  defp addresses(handles) do
    [
      {"task", handles.task, "title"},
      {"task", handles.task, "lane"},
      {"fact", handles.clinician_facts.kept, "value"},
      {"fact", handles.clinician_facts.erased, "value"},
      {"task", handles.recipe_task, "title"}
    ]
  end

  defp explain(actor, tenant, {type, id, attribute}),
    do:
      Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
        actor: actor,
        tenant: tenant
      )

  test "a second fill finds every row and writes no audit event", ctx do
    first = DemoData.populate(ctx.tenant, ctx.admin)
    events = Ash.count!(EventLog, authorize?: false, tenant: ctx.tenant)

    assert DemoData.populate(ctx.tenant, ctx.admin) == first
    assert Ash.count!(EventLog, authorize?: false, tenant: ctx.tenant) == events
  end

  test "the reader gets an answer for every address, whose recorded steps come from the log",
       ctx do
    handles = DemoData.populate(ctx.tenant, ctx.admin)

    for address <- addresses(handles) do
      assert {:ok, %{explanation: explanation}} = explain(ctx.reader, ctx.tenant, address)
      assert explanation.steps != [], "no step for #{inspect(address)}"
    end
  end

  test "a person with no read grant finds none of them", ctx do
    handles = DemoData.populate(ctx.tenant, ctx.admin)

    for address <- addresses(handles) do
      assert {:error, %Ash.Error.Invalid{}} = explain(ctx.viewer, ctx.tenant, address)
    end
  end
end
