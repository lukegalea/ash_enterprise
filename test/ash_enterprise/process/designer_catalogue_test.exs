defmodule AshEnterprise.Process.DesignerCatalogueTest do
  @moduledoc """
  The three MFAs the designer consumes, in this application's terms.

  The load-bearing property is on `actions/1`: it is a rendering of the invoker's registry,
  not a second list. Everything else is plumbing — the decision entries shaped as the panel
  expects, and an editor path that points at the DMN editor route this app actually serves.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{DesignerCatalogue, Resolver}

  setup do
    Seeder.seed_platform_organization()

    %{organization: organization, user: admin} =
      Seeder.seed_tenant(
        unique_name: "catalogue-#{System.unique_integer([:positive])}",
        email: "catalogue-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    %{tenant: organization.id, admin: admin}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp publish_risk_decision!(tenant) do
    xml = File.read!("priv/dmn/access_request_risk.dmn")

    definition =
      Decisions.Definition.create!(
        %{key: "access_request.risk", name: "Access request risk", xml: xml},
        opts(tenant)
      )

    assert definition.errors in [nil, []]

    Decisions.Definition.publish!(definition, opts(tenant))
  end

  # The socket double: what `Helpers.current_actor/1` and the `assign_tenant` on_mount leave
  # on a real socket is exactly `assigns.current_user` and `assigns.current_tenant`.
  defp socket(admin, tenant), do: %{assigns: %{current_user: admin, current_tenant: tenant}}

  describe "decisions/1" do
    test "entries are shaped for the business rule panel", %{admin: admin, tenant: tenant} do
      publish_risk_decision!(tenant)

      assert [%{key: "access_request.risk"} = entry] =
               DesignerCatalogue.decisions(socket(admin, tenant))

      assert entry.name == "Access request risk"
      assert entry.status == :published
      assert entry.latest_published_version == 1
      assert entry.has_draft == false

      # What the document declares, projected from the compiled snapshot: the panel uses it
      # to show the named decisions inside the key and the inputs they are called with.
      assert [%{name: "RiskTier"} = risk] = entry.decisions

      assert Enum.map(risk.inputs, & &1.name) == ["requestedRoleTier", "justificationLength"]
      assert [%{name: "RiskTier"}] = risk.outputs
    end

    test "a key with a draft in flight says so", %{admin: admin, tenant: tenant} do
      published = publish_risk_decision!(tenant)

      Decisions.Definition.create!(
        %{key: "access_request.risk", name: "Access request risk", xml: published.xml},
        opts(tenant)
      )

      assert [%{status: :draft, has_draft: true, latest_published_version: 1}] =
               DesignerCatalogue.decisions(socket(admin, tenant))
    end

    test "a socket with nobody in it degrades to an empty catalogue" do
      # The designer rescues a failing catalogue to the same empty list; the rescue lives in
      # the host so the outage is logged where the tenant it happened to is known.
      assert DesignerCatalogue.decisions(%{assigns: %{current_user: nil, current_tenant: nil}}) ==
               []
    end
  end

  describe "actions/1" do
    test "is the invoker's registry, rendered" do
      assert DesignerCatalogue.actions(%{assigns: %{}}) ==
               AshEnterprise.Process.ActionInvoker.catalogue()
    end
  end

  describe "decision_editor_path/2" do
    test "points at the DMN editor route this application serves" do
      assert DesignerCatalogue.decision_editor_path("access_request.risk", %{assigns: %{}}) ==
               "/app/decisions/access_request.risk/editor"
    end
  end
end
