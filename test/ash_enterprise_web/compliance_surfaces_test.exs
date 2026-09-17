defmodule AshEnterpriseWeb.ComplianceSurfacesTest do
  @moduledoc """
  The compliance A2UI surfaces: they build valid A2UI payloads, they render
  the rows the actor's grants reach, and the door in front of them admits
  exactly the actors it should.

  The door matters more than the rendering. The compliance resources carry no
  row policies of their own (ADR 0035), so `ComplianceAuth` is the only thing
  between a signed-in user and the findings ledger — a test that only asserted
  "the surface renders" would pass with the door wired open.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Security.ActorContext
  alias AshEnterpriseWeb.A2ui.ComplianceEvaluationUI
  alias AshEnterpriseWeb.A2ui.FindingUI
  alias AshEnterpriseWeb.A2ui.PolicyBundleUI
  alias AshEnterpriseWeb.A2ui.ProfileUI
  alias AshEnterpriseWeb.A2ui.RuleSetRevisionUI
  alias AshEnterpriseWeb.A2ui.CatalogUI
  alias AshEnterpriseWeb.ComplianceAuth

  setup do
    seeded =
      AshEnterprise.Platform.Seeder.seed_tenant(
        unique_name: "comp-a2ui-#{System.unique_integer([:positive])}"
      )

    admin =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    %{seeded: seeded, admin: admin, tenant: seeded.organization.id}
  end

  describe "surface construction" do
    test "every compliance surface builds a valid A2UI message list", ctx do
      for mod <- [
            FindingUI,
            ComplianceEvaluationUI,
            PolicyBundleUI,
            RuleSetRevisionUI,
            CatalogUI,
            ProfileUI
          ] do
        messages = AshA2ui.Info.build_surface(mod, actor: ctx.admin, tenant: ctx.tenant)

        assert is_list(messages), "#{inspect(mod)} did not build a message list"
        assert messages != [], "#{inspect(mod)} built no messages"

        # UI-as-data: maps all the way down, no markup, no script.
        assert Enum.all?(messages, &is_map/1), "#{inspect(mod)} emitted a non-map message"
      end
    end
  end

  describe "the findings surface renders projected rows" do
    test "a finding on the actor's grain is visible on the surface", ctx do
      org = ctx.tenant
      AshEnterprise.Compliance.Seeds.seed(org)

      # Recording is an officer action — asserted, not assumed.
      assert :ok =
               AshEnterprise.Compliance.Kyc.record_review(
                 org,
                 "surface-1",
                 [
                   ["customer", "status", "active"],
                   ["customer", "jurisdiction", "unknown"]
                 ],
                 actor: ctx.admin
               )

      events = compliance_events()
      :ok = AshCompliance.Testing.drain_sync(AshEnterprise.Compliance.Projector, events)

      assert row_count(FindingUI, ctx.admin, org) > 0
    end
  end

  describe "the compliance door" do
    test "an administrator with the finding grant passes", ctx do
      assert ComplianceAuth.authorized?(ctx.admin)
    end

    test "an actor with no roles is turned away" do
      stranger =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "no-compliance-#{System.unique_integer([:positive])}@example.com",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create!()

      refute ComplianceAuth.authorized?(stranger)
      refute ComplianceAuth.authorized?(nil)
    end
  end

  defp compliance_events do
    AshEnterprise.Compliance.EventLog
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn event ->
      %{
        id: event.id,
        practice_id: event.practice_id,
        user_id: event.user_id,
        occurred_at: event.occurred_at,
        metadata: event.metadata,
        resource: event.resource,
        action: event.action,
        action_type: event.action_type
      }
    end)
  end

  defp row_count(ui, actor, tenant) do
    ui
    |> AshA2ui.Info.build_data_model(actor: actor, tenant: tenant)
    |> case do
      %{"updateDataModel" => %{"value" => %{"records" => records}}} -> length(records)
      _other -> 0
    end
  end
end
