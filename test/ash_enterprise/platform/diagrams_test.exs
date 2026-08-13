defmodule AshEnterprise.Platform.DiagramsTest do
  @moduledoc """
  The introspection payoff, asserted rather than assumed.

  Thesis 1 claims that a sufficiently complete declarative description lets the
  diagrams be *derived*. These tests hold that claim to account: if a future
  change makes a domain undiagrammable — a resource the ER generator cannot
  walk, a policy set the flow generator cannot render — it fails here rather
  than showing up as a blank panel in `/clarity` that nobody notices.

  They also pin the specific things the diagrams are supposed to reveal:

    * inherited platform attributes appear in the ER diagram, so
      `AshEnterprise.Platform.Resource` is genuinely introspectable and not a
      macro that hides what it adds;
    * the policy flowchart shows the three grant paths in order, which is
      `docs/manifesto/03-authorization-is-data.md` rendered as a picture;
    * the lifecycle state machine shows its transitions, which is why the
      state-machine work had to precede this.
  """

  use ExUnit.Case, async: true

  @domains [
    AshEnterprise.Accounts,
    AshEnterprise.Security,
    AshEnterprise.Audit
  ]

  defp compose(diagram), do: diagram |> AshDiagram.compose() |> IO.iodata_to_binary()

  describe "entity relationship diagrams" do
    test "every domain is diagrammable" do
      er = @domains |> AshDiagram.Data.EntityRelationship.for_domains() |> compose()

      assert er =~ "erDiagram"
      assert er =~ "Accounts.BusinessUnit"
      assert er =~ "Security.Role"
      assert er =~ "Audit.EventLog"
    end

    test "inherited platform attributes are visible, not hidden by the base resource" do
      er =
        [AshEnterprise.Accounts.BusinessUnit]
        |> AshDiagram.Data.EntityRelationship.for_resources()
        |> compose()

      # None of these are declared in business_unit.ex -- they arrive from
      # AshEnterprise.Platform.SystemAttributes. Their presence here is the
      # difference between an extension and a macro that obscures its output.
      for inherited <- [
            "organization_id",
            "owning_business_unit_id",
            "lifecycle_status",
            "version_number",
            "created_by_id"
          ] do
        assert er =~ inherited, "expected inherited attribute #{inherited} in the ER diagram"
      end
    end
  end

  describe "policy diagrams" do
    test "the three grant paths render in evaluation order" do
      policy =
        AshEnterprise.Accounts.BusinessUnit |> AshDiagram.Data.Policy.for_resource() |> compose()

      assert policy =~ "flowchart"

      # The nodes are labelled with each check's `describe/1` output, not its
      # module name. That makes those descriptions USER-FACING documentation
      # rather than code comments -- they are what an auditor reads off the
      # diagram -- so they are asserted here to keep them honest.
      bypass = "actor is a system actor"
      role = "actor holds a role granting this action at sufficient depth"
      share = "record is shared with the actor or one of their teams"
      hierarchy = "record belongs to someone the actor is above in the hierarchy"

      for label <- [bypass, role, share, hierarchy] do
        assert policy =~ label, "expected the policy diagram to describe: #{label}"
      end

      # Ordering matters: a bypass evaluated after the union would be pointless,
      # and the three grant paths must appear as a union in a fixed order.
      positions =
        Enum.map([bypass, role, share, hierarchy], fn needle ->
          policy |> String.split(needle) |> hd() |> String.length()
        end)

      assert positions == Enum.sort(positions)
    end
  end

  describe "state machine diagrams" do
    test "the lifecycle transitions render" do
      chart = AshStateMachine.Charts.mermaid_state_diagram(AshEnterprise.Accounts.BusinessUnit)

      assert chart =~ "stateDiagram"
      assert chart =~ "active --> inactive: deactivate"
      assert chart =~ "inactive --> active: activate"
    end
  end

  describe "class diagrams" do
    test "every domain is diagrammable" do
      cls = @domains |> AshDiagram.Data.Class.for_domains() |> compose()

      assert cls =~ "classDiagram"
      assert String.length(cls) > 1_000
    end
  end
end
